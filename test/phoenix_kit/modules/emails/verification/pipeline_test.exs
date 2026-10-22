defmodule PhoenixKit.Modules.Emails.Verification.PipelineTest do
  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.FakeResolver

  @mx {:ok, [%{host: "mx.good.example", pref: 10}]}

  defp run(email, opts \\ []),
    do: Pipeline.run(email, Keyword.put_new(opts, :resolver, FakeResolver))

  defp steps(%Result{log: log}), do: Enum.map(log, & &1["step"])

  describe "verdicts before DNS (the resolver must not be asked)" do
    test "malformed input is invalid at the syntax level" do
      for bad <- ["", "plain", "a@b@c.com", "a..b@good-fixture.org", "a@localhost", nil, 42] do
        result = run(bad)

        assert {result.status, result.reason, result.level} == {"invalid", "syntax", "syntax"},
               "#{inspect(bad)} -> #{inspect({result.status, result.reason, result.level})}"
      end

      assert FakeResolver.calls() == []
    end

    test "an unknown top-level domain is invalid, at the dictionary level" do
      result = run("john@good-fixture.invalidtld")
      assert {result.status, result.reason, result.level} == {"invalid", "bad_tld", "dict"}
      assert steps(result) == ["normalize", "syntax", "marks", "tld"]
      assert FakeResolver.calls() == []
    end

    test "a disposable domain is temp and flagged" do
      result = run("john@mailinator.com")
      assert {result.status, result.reason, result.level} == {"temp", "disposable", "dict"}
      assert result.disposable
      assert FakeResolver.calls() == []
    end
  end

  describe "DNS" do
    test "an address that passes everything is not_sure at level mx (domain OK, no SMTP)" do
      FakeResolver.put("good-fixture.org", mx: @mx)
      result = run("John@Good-Fixture.ORG")

      assert result.status == "not_sure"
      assert result.reason == "smtp_disabled"
      assert result.level == "mx"
      assert result.mx == "mx.good.example"
      assert result.email == "John@good-fixture.org"
      assert result.domain == "good-fixture.org"
      assert result.catch_all == nil
      assert result.source == "direct"
      assert %DateTime{} = result.checked_at
      refute result.status == "valid"
    end

    test "the log lists every step that ran, with timings, and marks the skipped SMTP step" do
      FakeResolver.put("good-fixture.org", mx: @mx)
      result = run("john@good-fixture.org")

      assert steps(result) == ~w(normalize syntax marks tld disposable flags mx smtp)
      assert Enum.all?(result.log, &(is_float(&1["ms"]) and &1["ms"] >= 0))
      assert Enum.map(result.log, & &1["outcome"]) == ~w(ok ok ok ok ok ok ok skipped)

      mx_line = Enum.find(result.log, &(&1["step"] == "mx"))
      assert %{"hosts" => 1, "implicit" => false, "source" => "dns"} = mx_line
    end

    test "a failing step is logged as failed and ends the log" do
      result = run("john@good-fixture.invalidtld")
      assert %{"step" => "tld", "outcome" => "fail"} = List.last(result.log)
    end

    test "a domain without MX but with an address is accepted (implicit MX)" do
      FakeResolver.put("good-fixture.org",
        mx: {:error, :no_records},
        addr: {:ok, [{192, 0, 2, 1}]}
      )

      result = run("john@good-fixture.org")

      assert {result.status, result.mx} == {"not_sure", "good-fixture.org"}
      assert %{"implicit" => true} = Enum.find(result.log, &(&1["step"] == "mx"))
    end

    test "no MX and no address is invalid no_mx" do
      for dns <- [
            [mx: {:error, :nxdomain}],
            [mx: {:error, :no_records}, addr: {:error, :no_records}],
            [mx: {:ok, [%{host: ".", pref: 0}]}]
          ] do
        FakeResolver.put("good-fixture.org", dns)
        result = run("john@good-fixture.org")
        assert {result.status, result.reason, result.level} == {"invalid", "no_mx", "mx"}
      end
    end

    test "SERVFAIL and timeout are temp dns_error, not invalid" do
      for reason <- [:servfail, :timeout] do
        FakeResolver.put("good-fixture.org", mx: {:error, reason})
        result = run("john@good-fixture.org")
        assert {result.status, result.reason, result.level} == {"temp", "dns_error", "mx"}
        assert %{"error" => error} = Enum.find(result.log, &(&1["step"] == "mx"))
        assert error == Atom.to_string(reason)
      end
    end

    test "the MX answer is cached per domain; the second address does not hit the resolver" do
      FakeResolver.put("good-fixture.org", mx: @mx)
      assert run("a@good-fixture.org").status == "not_sure"
      assert run("b@good-fixture.org").status == "not_sure"

      assert FakeResolver.calls() == [{:mx, "good-fixture.org"}]

      assert %{"source" => "cache"} =
               run("c@good-fixture.org").log |> Enum.find(&(&1["step"] == "mx"))
    end

    test "a no-MX answer is cached too, a transient failure is not" do
      FakeResolver.put("gone-fixture.org", mx: {:error, :nxdomain})
      run("a@gone-fixture.org")
      run("b@gone-fixture.org")
      # asked twice (the first nxdomain is confirmed), then served from the cache
      assert FakeResolver.calls() == List.duplicate({:mx, "gone-fixture.org"}, 2)

      FakeResolver.put("flaky-fixture.org", mx: {:error, :timeout})
      run("a@flaky-fixture.org")
      run("b@flaky-fixture.org")
      assert Enum.count(FakeResolver.calls(), &(&1 == {:mx, "flaky-fixture.org"})) == 2
    end

    test "a first nxdomain that is not confirmed does not make the address invalid" do
      FakeResolver.put("good-fixture.org", mx: [{:error, :nxdomain}, @mx])
      result = run("john@good-fixture.org")
      assert {result.status, result.reason} == {"not_sure", "smtp_disabled"}

      assert {:hit, {:ok, _}} =
               DomainCache.fetch_mx("good-fixture.org", PhoenixKit.Utils.Date.utc_now())
    end

    test "a first nxdomain whose confirmation fails is temp dns_error, and nothing is cached" do
      FakeResolver.put("good-fixture.org", mx: [{:error, :nxdomain}, {:error, :timeout}])
      result = run("john@good-fixture.org")

      assert {result.status, result.reason, result.level} == {"temp", "dns_error", "mx"}
      assert :miss = DomainCache.fetch_mx("good-fixture.org", PhoenixKit.Utils.Date.utc_now())
    end

    test "a confirmed nxdomain is invalid no_mx and cached" do
      FakeResolver.put("good-fixture.org", mx: [{:error, :nxdomain}, {:error, :nxdomain}])
      result = run("john@good-fixture.org")

      assert {result.status, result.reason, result.level} == {"invalid", "no_mx", "mx"}

      assert {:hit, {:error, :nxdomain}} =
               DomainCache.fetch_mx("good-fixture.org", PhoenixKit.Utils.Date.utc_now())
    end

    test "MX hosts that are not host names never reach the verdict" do
      FakeResolver.put("good-fixture.org",
        mx: {:ok, [%{host: "bad\0host.example", pref: 1}, %{host: "mx.good.example", pref: 5}]}
      )

      result = run("john@good-fixture.org")
      assert {result.status, result.mx} == {"not_sure", "mx.good.example"}

      FakeResolver.put("other-fixture.org", mx: {:ok, [%{host: "bad\0host.example", pref: 1}]})
      other = run("john@other-fixture.org")
      assert {other.status, other.reason} == {"temp", "dns_error"}
    end

    test "a stale cache row is re-resolved" do
      FakeResolver.put("good-fixture.org", mx: @mx)
      old = DateTime.add(PhoenixKit.Utils.Date.utc_now(), -48 * 3600, :second)
      DomainCache.store_mx("good-fixture.org", {:error, :nxdomain}, old)

      assert run("a@good-fixture.org").status == "not_sure"
      assert FakeResolver.calls() == [{:mx, "good-fixture.org"}]
    end
  end

  describe "flags" do
    setup do
      FakeResolver.put("gmail.com", mx: {:ok, [%{host: "gmail-smtp-in.l.google.com", pref: 5}]})
      FakeResolver.put("good-fixture.org", mx: @mx)
      :ok
    end

    test "free provider" do
      assert %{free: true, role: false, disposable: false, status: "not_sure"} =
               run("john@gmail.com")
    end

    test "role account" do
      assert %{free: false, role: true, status: "not_sure"} = run("info@good-fixture.org")
      assert %{role: true} = run("Sales+q3@good-fixture.org")
    end

    test "flags never decide the verdict" do
      assert run("info@gmail.com").status == run("john@good-fixture.org").status
    end
  end

  describe "alias strip" do
    setup do
      FakeResolver.put("good-fixture.org", mx: @mx)
      :ok
    end

    defp normalize_line(result), do: Enum.find(result.log, &(&1["step"] == "normalize"))

    test "user+tag@domain is checked as user@domain, stored under the address as given" do
      result = run("John+News@Good-Fixture.org")

      assert result.email == "John+News@good-fixture.org"
      assert normalize_line(result)["checked_as"] == "John@good-fixture.org"
      assert result.status == "not_sure"
    end

    test "an address without a tag logs no stripped form" do
      refute Map.has_key?(normalize_line(run("john@good-fixture.org")), "checked_as")
    end

    test "a tag with no user in front of it is left alone; an empty tag is dropped" do
      refute Map.has_key?(normalize_line(run("+tag@good-fixture.org")), "checked_as")

      assert normalize_line(run("john+@good-fixture.org"))["checked_as"] ==
               "john@good-fixture.org"
    end

    test "only the first + splits, and the stripped form is what the dictionaries see" do
      assert normalize_line(run("a+b+c@good-fixture.org"))["checked_as"] == "a@good-fixture.org"
      assert %{role: true} = run("info+q3@good-fixture.org")
      assert %{fake: true} = run("asdfgh+tag@good-fixture.org")
    end

    test "the stripped form must pass the syntax check too" do
      result = run("user.+tag@good-fixture.org")

      assert {result.status, result.reason, result.level} == {"invalid", "syntax", "syntax"}

      assert %{"detail" => "local_dots", "outcome" => "fail"} =
               Enum.find(result.log, &(&1["step"] == "syntax"))

      assert FakeResolver.calls() == []
      assert result.email == "user.+tag@good-fixture.org"
    end

    test "a tag after a clean local part still passes" do
      assert run("user.name+tag@good-fixture.org").status == "not_sure"
    end

    test "the queue is asked about the stripped address, and the result keeps the tag" do
      Settings.update_setting_with_module("email_verify_smtp_mode", "runner", "email_system")

      result = run("john+tag@good-fixture.org", smtp: :enqueue)

      assert {result.status, result.reason} == {"not_sure", "smtp_pending"}
      assert result.email == "john+tag@good-fixture.org"
    end
  end

  describe "the disposable status setting" do
    defp set_disposable_status(value) do
      Settings.update_setting_with_module("email_verify_disposable_status", value, "email_system")
    end

    test "defaults to temp" do
      assert Config.disposable_status() == "temp"
      assert %{status: "temp", reason: "disposable"} = run("john@mailinator.com")
    end

    test "invalid makes a disposable domain invalid, the reason and flag stay" do
      set_disposable_status("invalid")
      result = run("john@mailinator.com")

      assert {result.status, result.reason, result.level} == {"invalid", "disposable", "dict"}
      assert result.disposable
      assert FakeResolver.calls() == []
    end

    test "case and surrounding spaces are ignored; an unknown value falls back to temp" do
      set_disposable_status(" INVALID ")
      assert Config.disposable_status() == "invalid"

      for value <- ["temp", "bogus", ""] do
        set_disposable_status(value)
        assert run("john@mailinator.com").status == "temp", "setting #{inspect(value)}"
      end
    end
  end

  describe "SMTP step" do
    setup do
      FakeResolver.put("good-fixture.org", mx: @mx)
      :ok
    end

    defp set_mode(mode),
      do: Settings.update_setting_with_module("email_verify_smtp_mode", mode, "email_system")

    test "is skipped while the mode is off (the default), even when asked to queue" do
      result = run("john@good-fixture.org", smtp: :enqueue)

      assert {result.status, result.reason, result.level} == {"not_sure", "smtp_disabled", "mx"}
      assert List.last(result.log)["outcome"] == "skipped"
    end

    test "is skipped when the mode is on but nobody asked to queue: a sync caller never waits" do
      set_mode("runner")
      result = run("john@good-fixture.org")

      assert {result.status, result.reason, result.level} == {"not_sure", "smtp_disabled", "mx"}
    end

    test "when asked to queue in runner mode, a passing address is pending at level mx" do
      set_mode("runner")
      result = run("john@good-fixture.org", smtp: :enqueue)

      assert {result.status, result.reason, result.level} == {"not_sure", "smtp_pending", "mx"}
      assert result.catch_all == nil
      assert %{"step" => "smtp", "outcome" => "ok", "mode" => "runner"} = List.last(result.log)
    end

    test "local mode queues too" do
      set_mode("local")

      assert %{reason: "smtp_pending"} = run("john@good-fixture.org", smtp: :enqueue)
    end

    test "an address that fails an earlier step never reaches the SMTP step" do
      set_mode("runner")
      result = run("john@good-fixture.invalidtld", smtp: :enqueue)

      assert result.reason == "bad_tld"
      refute "smtp" in steps(result)
    end
  end
end
