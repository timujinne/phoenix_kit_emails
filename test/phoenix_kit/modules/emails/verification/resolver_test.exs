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

      assert FakeResolver.calls() == [{:mx, "a-only.example"}, {:addr, "a-only.example"}]
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
      assert FakeResolver.calls() == [{:mx, "gone.example"}]
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

  # Real DNS. Excluded by default (see test_helper.exs); run with
  # `mix test --include external`.
  describe "Resolver.Inet against live DNS" do
    @describetag :external

    test "a domain with MX records" do
      assert {:ok, [_ | _] = records} = Inet.lookup_mx("gmail.com", 5_000)
      assert Enum.all?(records, &(is_binary(&1.host) and is_integer(&1.pref)))
    end

    test "hydroforce.ee resolves to mail hosts" do
      assert {:ok, %{hosts: [_ | _]}} =
               Resolver.resolve("hydroforce.ee", resolver: Inet, timeout: 5_000)
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
