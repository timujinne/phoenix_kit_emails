defmodule PhoenixKit.Modules.Emails.Verification.ResolverTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKit.Modules.Emails.Verification.Resolver.Inet
  alias PhoenixKitEmails.Test.FakeResolver

  defp resolve(domain), do: Resolver.resolve(domain, resolver: FakeResolver, timeout: 100)

  describe "resolve/2" do
    test "returns MX hosts, preferred first, lowercased and without the root dot" do
      FakeResolver.put("example.com",
        mx:
          {:ok, [%{host: "Backup.Example.com.", pref: 20}, %{host: "mx1.example.com", pref: 10}]}
      )

      assert {:ok,
              %{
                implicit: false,
                hosts: [
                  %{host: "mx1.example.com", pref: 10},
                  %{host: "backup.example.com", pref: 20}
                ]
              }} = resolve("example.com")

      assert FakeResolver.calls() == [{:mx, "example.com"}]
    end

    test "falls back to the domain itself (implicit MX) when only an address exists" do
      FakeResolver.put("a-only.example",
        mx: {:error, :no_records},
        addr: {:ok, [{192, 0, 2, 1}]}
      )

      assert {:ok, %{implicit: true, hosts: [%{host: "a-only.example", pref: 0}]}} =
               resolve("a-only.example")

      assert FakeResolver.calls() ==
               [{:mx, "a-only.example"}, {:mx, "a-only.example"}, {:addr, "a-only.example"}]
    end

    test "no MX and no address is :no_records" do
      FakeResolver.put("empty.example", mx: {:error, :no_records}, addr: {:error, :no_records})
      assert {:error, :no_records} = resolve("empty.example")

      FakeResolver.put("empty2.example", mx: {:error, :no_records}, addr: {:ok, []})
      assert {:error, :no_records} = resolve("empty2.example")
    end

    test "a nonexistent domain stops at the MX query" do
      FakeResolver.put("gone.example", mx: {:error, :nxdomain})
      assert {:error, :nxdomain} = resolve("gone.example")
      assert Enum.all?(FakeResolver.calls(), &match?({:mx, _}, &1))
    end

    test "a transient MX failure is not turned into an address fallback" do
      for reason <- [:servfail, :timeout] do
        FakeResolver.put("flaky.example", mx: {:error, reason}, addr: {:ok, [{192, 0, 2, 1}]})
        assert {:error, ^reason} = resolve("flaky.example")
      end

      assert Enum.all?(FakeResolver.calls(), &match?({:mx, _}, &1))
    end

    test "a transient failure of the address fallback is reported as such" do
      FakeResolver.put("flaky.example", mx: {:error, :no_records}, addr: {:error, :timeout})
      assert {:error, :timeout} = resolve("flaky.example")
    end

    test "a null MX (RFC 7505) means the domain takes no mail" do
      FakeResolver.put("nullmx.example", mx: {:ok, [%{host: ".", pref: 0}]})
      assert {:error, :null_mx} = resolve("nullmx.example")

      FakeResolver.put("nullmx2.example", mx: {:ok, [%{host: "", pref: 0}]})
      assert {:error, :null_mx} = resolve("nullmx2.example")
    end

    test "a null MX next to real ones is dropped" do
      FakeResolver.put("mixed.example",
        mx: {:ok, [%{host: ".", pref: 0}, %{host: "mx.mixed.example", pref: 5}]}
      )

      assert {:ok, %{hosts: [%{host: "mx.mixed.example"}]}} = resolve("mixed.example")
    end
  end

  describe "a negative answer is confirmed before it is believed" do
    test "nxdomain twice is nxdomain" do
      FakeResolver.put("gone.example", mx: {:error, :nxdomain})
      assert {:error, :nxdomain} = resolve("gone.example")
      assert FakeResolver.calls() == [{:mx, "gone.example"}, {:mx, "gone.example"}]
    end

    test "a first nxdomain that the second query contradicts is not believed" do
      FakeResolver.put("gmail-like.example",
        mx: [{:error, :nxdomain}, {:ok, [%{host: "mx.gmail-like.example", pref: 5}]}]
      )

      assert {:ok, %{hosts: [%{host: "mx.gmail-like.example"}], implicit: false}} =
               resolve("gmail-like.example")
    end

    test "a confirmation that fails transiently makes the whole answer transient" do
      for reason <- [:servfail, :timeout] do
        FakeResolver.put("flaky.example", mx: [{:error, :nxdomain}, {:error, reason}])
        assert {:error, ^reason} = resolve("flaky.example")
      end
    end

    test "the confirmation waits the configured pause, a first answer that needs none does not" do
      FakeResolver.put("gone.example", mx: {:error, :nxdomain})
      FakeResolver.put("fine.example", mx: {:ok, [%{host: "mx.fine.example", pref: 5}]})
      FakeResolver.put("flaky.example", mx: {:error, :timeout})

      elapsed = fn domain, pause ->
        {micros, _} =
          :timer.tc(fn ->
            Resolver.resolve(domain,
              resolver: FakeResolver,
              timeout: 100,
              confirm_pause_ms: pause
            )
          end)

        div(micros, 1_000)
      end

      assert elapsed.("gone.example", 80) >= 80
      assert elapsed.("gone.example", 0) < 80
      assert elapsed.("fine.example", 400) < 400
      assert elapsed.("flaky.example", 400) < 400
    end

    test "a first attempt that fails transiently is returned as it is, not retried into nxdomain" do
      FakeResolver.put("flaky.example", mx: [{:error, :timeout}, {:error, :nxdomain}])
      assert {:error, :timeout} = resolve("flaky.example")
      assert FakeResolver.calls() == [{:mx, "flaky.example"}]
    end

    test "an empty MX answer is confirmed as well, before the address fallback" do
      FakeResolver.put("late-mx.example",
        mx: [{:error, :no_records}, {:ok, [%{host: "mx.late-mx.example", pref: 1}]}],
        addr: {:ok, [{192, 0, 2, 1}]}
      )

      assert {:ok, %{implicit: false}} = resolve("late-mx.example")
      assert FakeResolver.calls() == [{:mx, "late-mx.example"}, {:mx, "late-mx.example"}]
    end

    test "the address fallback is confirmed too" do
      FakeResolver.put("a-late.example",
        mx: {:error, :no_records},
        addr: [{:error, :nxdomain}, {:ok, [{192, 0, 2, 1}]}]
      )

      assert {:ok, %{implicit: true}} = resolve("a-late.example")

      FakeResolver.put("a-flaky.example",
        mx: {:error, :no_records},
        addr: [{:error, :no_records}, {:error, :timeout}]
      )

      assert {:error, :timeout} = resolve("a-flaky.example")
    end

    test "a positive answer, a null MX and a transient error cost one query" do
      FakeResolver.put("mx.example", mx: {:ok, [%{host: "mx.mx.example", pref: 1}]})
      FakeResolver.put("null.example", mx: {:ok, [%{host: ".", pref: 0}]})
      FakeResolver.put("down.example", mx: {:error, :servfail})
      for domain <- ["mx.example", "null.example", "down.example"], do: resolve(domain)
      assert length(FakeResolver.calls()) == 3
    end
  end

  describe "MX hosts that are not host names" do
    defp mx_hosts(hosts) do
      FakeResolver.put("bad-mx.example",
        mx: {:ok, hosts |> Enum.with_index(1) |> Enum.map(fn {h, i} -> %{host: h, pref: i} end)}
      )

      resolve("bad-mx.example")
    end

    test "are dropped when a good one remains" do
      assert {:ok, %{hosts: [%{host: "mx.good.example"}]}} =
               mx_hosts(["bad host.example", "mx.good.example", "nul\0.example"])
    end

    test "NUL, control characters, spaces, empty labels and non-ASCII are all refused" do
      for bad <- [
            "mx\0.example",
            "mx\n.example",
            "mx .example",
            "a..example",
            ".mx.example",
            "mx.exam_ple.com",
            "m\u00fcnchen.example",
            "-mx.example",
            "mx-.example",
            "<script>.example",
            String.duplicate("a", 64) <> ".example",
            String.duplicate("a.", 127) <> "ab"
          ] do
        assert {:error, :servfail} = mx_hosts([bad]), "#{inspect(bad)} should be refused"
      end
    end

    test "an all-bad set behaves like a SERVFAIL, and is not an empty answer" do
      assert {:error, :servfail} = mx_hosts(["a b", "c\0d"])
      assert FakeResolver.calls() == [{:mx, "bad-mx.example"}]
    end

    test "a good host at the length limits is kept" do
      long =
        Enum.join(
          [
            String.duplicate("a", 63),
            String.duplicate("b", 63),
            String.duplicate("c", 63),
            String.duplicate("d", 61)
          ],
          "."
        )

      assert byte_size(long) == 253
      assert {:ok, %{hosts: [%{host: ^long}]}} = mx_hosts([long])
      assert {:error, :servfail} = mx_hosts([long <> "e"])
    end

    test "punycode, digits and hyphens inside labels are fine" do
      assert {:ok, %{hosts: [%{host: "xn--mnchen-3ya.example"}, %{host: "mx-1.mail2.example"}]}} =
               mx_hosts(["xn--mnchen-3ya.example", "mx-1.mail2.example"])
    end
  end

  describe "an unreliable hijack probe" do
    test "an implicit MX found while the probe was unanswered is marked uncacheable" do
      FakeResolver.put("a-only.example", mx: {:error, :no_records}, addr: {:ok, [{192, 0, 2, 1}]})

      assert {:ok, %{implicit: true, cacheable: false}} =
               Resolver.resolve("a-only.example",
                 resolver: FakeResolver,
                 timeout: 100,
                 hijack_ips: fn -> :error end
               )
    end

    test "a known probe answer leaves the resolution cacheable" do
      FakeResolver.put("a-only.example", mx: {:error, :no_records}, addr: {:ok, [{192, 0, 2, 1}]})

      assert {:ok, %{implicit: true} = resolution} =
               Resolver.resolve("a-only.example",
                 resolver: FakeResolver,
                 timeout: 100,
                 hijack_ips: fn -> {:ok, []} end
               )

      refute Map.has_key?(resolution, :cacheable)
    end
  end

  describe "Resolver.Inet error classification" do
    test "tells final answers from missing ones" do
      assert Inet.classify_error(:nxdomain) == :nxdomain
      assert Inet.classify_error({:nxdomain, :msg}) == :nxdomain
      assert Inet.classify_error({:noerror, :msg}) == :no_records
      assert Inet.classify_error(:timeout) == :timeout
      assert Inet.classify_error({:servfail, :msg}) == :servfail
    end

    test "anything unrecognised counts as no answer, so it is retried rather than cached" do
      assert Inet.classify_error(:formerr) == :servfail
      assert Inet.classify_error({:refused, :msg}) == :servfail
      assert Inet.classify_error(:weird) == :servfail
    end
  end

  describe "Resolver.Inet queries" do
    test "names are absolute, so the host's search domains never apply" do
      assert Inet.absolute_name("gmail.com") == ~c"gmail.com."
      assert Inet.absolute_name("gmail.com.") == ~c"gmail.com."
      assert Inet.absolute_name("pk-abc123.com") == ~c"pk-abc123.com."
    end

    test "the timeout is one deadline for the whole query, retries included" do
      assert {~c"gmail.com.", :in, :mx, opts, 3_000} = Inet.query_args("gmail.com", :mx, 3_000)
      assert Keyword.fetch!(opts, :timeout) == 3_000
      assert Keyword.fetch!(opts, :retry) == 2
    end
  end

  # Real DNS. Excluded by default (see test_helper.exs); run with
  # `mix test --include external`.
  describe "Resolver.Inet against live DNS" do
    @describetag :external

    test "a domain with MX records" do
      assert {:ok, [_ | _] = records} = Inet.lookup_mx("gmail.com", 5_000)
      assert Enum.all?(records, &(is_binary(&1.host) and is_integer(&1.pref)))
    end

    test "a domain with mail hosts resolves through the full pipeline" do
      assert {:ok, %{hosts: [_ | _]}} =
               Resolver.resolve("gmail.com", resolver: Inet, timeout: 5_000)
    end

    test "a guaranteed-nonexistent domain is :nxdomain, not a transient error" do
      assert {:error, :nxdomain} =
               Resolver.resolve("this-domain-does-not-exist.invalid",
                 resolver: Inet,
                 timeout: 5_000
               )
    end
  end
end
