defmodule PhoenixKit.Modules.Emails.Verification.HijackTest do
  @moduledoc """
  Anti-DNS-hijack: some resolvers answer NXDOMAIN with the address of a landing
  page; without a counter-measure a nonexistent domain would look like a mail
  server through the implicit-MX fallback. The probe cache is one per VM, so
  these tests are synchronous and clear it around each test.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Hijack
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKitEmails.Test.FakeResolver

  @portal {203, 0, 113, 9}
  @real {192, 0, 2, 1}
  @probe "probe.fixture.test"

  setup do
    Hijack.reset()
    on_exit(&Hijack.reset/0)
    :ok
  end

  defp probe(opts \\ []),
    do: Hijack.ips(Keyword.merge([resolver: FakeResolver, probe: @probe, timeout: 100], opts))

  describe "Resolver.resolve/2 with :hijack_ips" do
    defp resolve(domain, hijack),
      do: Resolver.resolve(domain, resolver: FakeResolver, timeout: 100, hijack_ips: hijack)

    test "the hijack address alone is not a mail server" do
      FakeResolver.put("ghost.example", mx: {:error, :no_records}, addr: {:ok, [@portal]})
      assert {:error, :no_records} = resolve("ghost.example", [@portal])
    end

    test "a real address next to the hijack one still counts" do
      FakeResolver.put("real.example", mx: {:error, :no_records}, addr: {:ok, [@portal, @real]})

      assert {:ok, %{implicit: true, hosts: [%{host: "real.example"}]}} =
               resolve("real.example", [@portal])
    end

    test "without hijack addresses nothing is subtracted" do
      FakeResolver.put("ghost.example", mx: {:error, :no_records}, addr: {:ok, [@portal]})
      assert {:ok, %{implicit: true}} = resolve("ghost.example", [])
    end

    test "the list is only computed when the address fallback is reached" do
      FakeResolver.put("mx.example", mx: {:ok, [%{host: "mx.mx.example", pref: 1}]})
      raising = fn -> raise "must not be called" end

      assert {:ok, %{implicit: false}} =
               Resolver.resolve("mx.example", resolver: FakeResolver, hijack_ips: raising)
    end

    test "real MX records are never filtered" do
      FakeResolver.put("mx.example", mx: {:ok, [%{host: "mx.mx.example", pref: 1}]})
      assert {:ok, %{hosts: [%{host: "mx.mx.example"}]}} = resolve("mx.example", [@portal])
    end
  end

  describe "Hijack.ips/1" do
    test "the addresses a nonexistent probe domain resolves to" do
      FakeResolver.put(@probe, addr: {:ok, [@portal]})
      assert probe() == {:ok, [@portal]}
    end

    test "an honest NXDOMAIN means no hijack" do
      assert probe() == {:ok, []}
    end

    test "the answer is cached per VM: the resolver is asked once" do
      FakeResolver.put(@probe, addr: {:ok, [@portal]})
      assert probe() == {:ok, [@portal]}
      assert probe() == {:ok, [@portal]}
      assert FakeResolver.calls() == [{:addr, @probe}]
    end

    test "an honest answer is cached too" do
      assert probe() == {:ok, []}
      assert probe() == {:ok, []}
      assert length(FakeResolver.calls()) == 1
    end

    test "a transient failure is not remembered, and is reported as unknown" do
      for reason <- [:timeout, :servfail] do
        FakeResolver.put(@probe, addr: {:error, reason})
        assert probe() == :error
      end

      FakeResolver.put(@probe, addr: {:ok, [@portal]})
      assert probe() == {:ok, [@portal]}
    end

    test "reset/0 forgets the answer" do
      FakeResolver.put(@probe, addr: {:ok, [@portal]})
      assert probe() == {:ok, [@portal]}
      Hijack.reset()
      FakeResolver.put(@probe, addr: {:error, :nxdomain})
      assert probe() == {:ok, []}
    end

    test "the default probe name is a fresh name under a real TLD" do
      assert Hijack.probe_domain() =~ ~r/\A[a-z0-9-]+\.com\z/
      refute Hijack.probe_domain() == Hijack.probe_domain()
    end
  end

  describe "in the pipeline" do
    defp run(email),
      do: Pipeline.run(email, resolver: FakeResolver, hijack_probe: @probe)

    defp cached?(domain),
      do: match?({:hit, _}, DomainCache.fetch_mx(domain, PhoenixKit.Utils.Date.utc_now()))

    test "an implicit MX is cached when the probe found no hijack" do
      FakeResolver.put("a-only-fixture.org", mx: {:error, :no_records}, addr: {:ok, [@real]})
      assert run("john@a-only-fixture.org").status == "not_sure"
      assert cached?("a-only-fixture.org")
    end

    test "an implicit MX found while the probe was unanswered is used but not cached" do
      FakeResolver.put(@probe, addr: {:error, :timeout})
      FakeResolver.put("a-only-fixture.org", mx: {:error, :no_records}, addr: {:ok, [@real]})

      result = run("john@a-only-fixture.org")
      assert {result.status, result.reason} == {"not_sure", "smtp_disabled"}
      refute cached?("a-only-fixture.org")

      # The next address asks again - and, the probe now answering, caches.
      FakeResolver.put(@probe, addr: {:error, :nxdomain})
      assert run("mary@a-only-fixture.org").status == "not_sure"
      assert cached?("a-only-fixture.org")
    end

    test "real MX records are cached whatever the probe says" do
      FakeResolver.put(@probe, addr: {:error, :timeout})
      FakeResolver.put("good-fixture.org", mx: {:ok, [%{host: "mx.good.example", pref: 10}]})
      run("john@good-fixture.org")
      assert cached?("good-fixture.org")
    end

    test "a hijacked NXDOMAIN does not look like a mail server" do
      FakeResolver.put(@probe, addr: {:ok, [@portal]})
      FakeResolver.put("ghost-fixture.org", mx: {:error, :no_records}, addr: {:ok, [@portal]})

      result = run("john@ghost-fixture.org")
      assert {result.status, result.reason, result.level} == {"invalid", "no_mx", "mx"}
    end

    test "without a hijack the same answer is an implicit MX" do
      FakeResolver.put("ghost-fixture.org", mx: {:error, :no_records}, addr: {:ok, [@portal]})

      result = run("john@ghost-fixture.org")
      assert {result.status, result.reason} == {"not_sure", "smtp_disabled"}
    end

    test "the probe is not asked when the domain has MX records" do
      FakeResolver.put("good-fixture.org", mx: {:ok, [%{host: "mx.good.example", pref: 10}]})
      run("john@good-fixture.org")
      assert FakeResolver.calls() == [{:mx, "good-fixture.org"}]
    end
  end
end
