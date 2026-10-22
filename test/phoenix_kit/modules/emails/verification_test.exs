defmodule PhoenixKit.Modules.Emails.VerificationTest do
  use PhoenixKitEmails.DataCase, async: true

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @mx {:ok, [%{host: "mx.fixture.org", pref: 10}]}

  defp verify(email, opts \\ []) do
    Verification.verify(email, Keyword.put_new(opts, :resolver, FakeResolver))
  end

  defp row_count, do: Repo.aggregate(Result, :count)

  setup do
    FakeResolver.put("fixture.org", mx: @mx)
    :ok
  end

  describe "enabled?/0" do
    test "defaults to true, with no SMTP involved" do
      assert Verification.enabled?()
      assert Verification.Config.smtp_mode() == "off"
    end

    test "follows email_verify_enabled, and not the SMTP mode" do
      Settings.update_boolean_setting_with_module("email_verify_enabled", false, "email_system")
      refute Verification.enabled?()

      Settings.update_boolean_setting_with_module("email_verify_enabled", true, "email_system")

      Settings.update_setting_with_module("email_verify_smtp_mode", "runner", "email_system")

      assert Verification.enabled?()
    end
  end

  describe "verify/2" do
    test "returns the verdict and stores it" do
      assert {:ok, %Result{} = result} = verify("John@Fixture.org")

      assert {result.status, result.reason, result.level} == {"not_sure", "smtp_disabled", "mx"}
      assert result.source == "direct"
      assert result.attempts == 1
      assert result.uuid

      stored = Repo.get_by!(Result, email: "john@fixture.org")
      assert stored.uuid == result.uuid
      assert stored.email == "John@fixture.org"
      assert stored.domain == "fixture.org"
      assert stored.mx == "mx.fixture.org"
      assert stored.checked_at == result.checked_at
      assert is_list(stored.log) and Enum.any?(stored.log, &(&1["step"] == "mx"))
    end

    test "stores invalid verdicts too, including malformed input" do
      assert {:ok, %Result{status: "invalid", reason: "syntax"}} = verify("not an email")
      assert {:ok, %Result{status: "temp", reason: "disposable"}} = verify("x@mailinator.com")

      assert Repo.get_by!(Result, email: "not an email").level == "syntax"
      assert Repo.get_by!(Result, email: "x@mailinator.com").disposable
    end

    test "the fake flag is stored and read back; it does not change the verdict" do
      assert {:ok, plain} = verify("john@fixture.org")
      assert {:ok, flagged} = verify("asdfgh@fixture.org")

      assert {flagged.status, flagged.reason} == {plain.status, plain.reason}
      assert %Result{fake: false, curse: false, typo: false} = plain
      assert %Result{fake: true, curse: false, typo: false} = flagged

      stored = Repo.get_by!(Result, email: "asdfgh@fixture.org")
      assert %Result{fake: true, curse: false, typo: false} = stored

      assert %{"asdfgh@fixture.org" => %Result{fake: true, source: "cache"}} =
               Verification.results_for(["asdfgh@fixture.org"])
    end

    test "a re-run overwrites the flags with the new ones" do
      assert {:ok, %Result{fake: true}} = verify("asdfgh@fixture.org")
      Repo.update_all(Result, set: [fake: false])
      assert {:ok, %Result{fake: false}} = verify("asdfgh@fixture.org")
      assert {:ok, %Result{fake: true}} = verify("asdfgh@fixture.org", force: true)
      assert Repo.get_by!(Result, email: "asdfgh@fixture.org").fake
    end

    test "blank input is reported but not stored" do
      before = row_count()
      assert {:ok, %Result{status: "invalid", reason: "syntax", email: nil}} = verify("  ")
      assert {:ok, %Result{status: "invalid"}} = verify(nil)
      assert row_count() == before
    end

    test "input a text column cannot hold is reported invalid and not stored, never a crash" do
      before = row_count()

      for bad <- ["a\0b@fixture.org", <<"a", 0xFF, "@fixture.org">>, <<0xFF, 0xFE, "xx">>] do
        assert {:ok, %Result{status: "invalid", reason: "syntax", email: nil}} = verify(bad)
      end

      assert row_count() == before
    end

    test "a fresh stored verdict is returned as a cache hit, without running the pipeline" do
      {:ok, first} = verify("a@fixture.org")
      FakeResolver.put("fixture.org", mx: {:error, :nxdomain})

      assert {:ok, second} = verify("A@FIXTURE.ORG")
      assert second.source == "cache"
      assert second.uuid == first.uuid
      assert second.status == "not_sure"
      assert second.checked_at == first.checked_at

      assert FakeResolver.calls() == [{:mx, "fixture.org"}]
      assert row_count() == 1
    end

    test "case differences in the address are one row" do
      verify("Jane@fixture.org")
      verify("jane@FIXTURE.org", force: true)

      assert Repo.aggregate(from(r in Result, where: r.domain == "fixture.org"), :count) == 1
    end

    test "an expired verdict is re-run and the row updated in place" do
      {:ok, first} = verify("old@fixture.org")
      age(first.uuid, days: 31)
      FakeResolver.put("fixture.org", mx: {:error, :nxdomain})
      Repo.delete_all(PhoenixKit.Modules.Emails.Verification.DomainCache)

      assert {:ok, second} = verify("old@fixture.org")
      assert second.source == "direct"
      assert second.uuid == first.uuid
      assert {second.status, second.reason} == {"invalid", "no_mx"}
      assert second.attempts == 2
      assert row_count() == 1
    end

    test "the result TTL is a setting" do
      {:ok, first} = verify("ttl@fixture.org")
      age(first.uuid, days: 3)
      assert {:ok, %{source: "cache"}} = verify("ttl@fixture.org")

      Settings.update_setting_with_module("email_verify_ttl_result_days", "2", "email_system")
      assert {:ok, %{source: "direct"}} = verify("ttl@fixture.org")
    end

    test "force: true re-runs a fresh verdict" do
      {:ok, _} = verify("force@fixture.org")
      assert {:ok, %{source: "direct", attempts: 2}} = verify("force@fixture.org", force: true)
    end

    test "a temp verdict is never served from the cache" do
      FakeResolver.put("flaky-fixture.org", mx: {:error, :timeout})
      assert {:ok, %{status: "temp", source: "direct"}} = verify("a@flaky-fixture.org")

      FakeResolver.put("flaky-fixture.org", mx: @mx)

      assert {:ok, %{status: "not_sure", source: "direct", attempts: 2}} =
               verify("a@flaky-fixture.org")
    end
  end

  describe "results_for/1" do
    test "returns stored verdicts keyed by the address as given" do
      verify("a@fixture.org")
      verify("junk")

      results =
        Verification.results_for(["A@Fixture.ORG", "junk", "unknown@fixture.org", nil, "  "])

      assert Map.keys(results) |> Enum.sort() == ["A@Fixture.ORG", "junk"]
      assert %Result{status: "not_sure", source: "cache"} = results["A@Fixture.ORG"]
      assert %Result{status: "invalid", reason: "syntax"} = results["junk"]
    end

    test "one unstorable address does not spoil the rest" do
      verify("a@fixture.org")

      results = Verification.results_for(["a@fixture.org", <<"a", 0xFF, "@x.org">>, "a\0b@x.org"])
      assert Map.keys(results) == ["a@fixture.org"]

      assert %{not_sure: 1, unchecked: 2} =
               Verification.summary(["a@fixture.org", <<0xFF>>, "x\0@y.org"])
    end

    test "an empty list is an empty map" do
      assert Verification.results_for([]) == %{}
    end

    test "handles a few thousand addresses in one go" do
      emails = for i <- 1..3_000, do: "user#{i}@fixture.org"
      assert Verification.results_for(emails) == %{}
      verify("user77@fixture.org")
      assert Map.keys(Verification.results_for(emails)) == ["user77@fixture.org"]
    end
  end

  describe "statuses_for/1" do
    test "returns status, reason and level only, keyed by the address as given" do
      verify("a@fixture.org")
      verify("junk")

      statuses =
        Verification.statuses_for(["A@Fixture.ORG", "junk", "unknown@fixture.org", nil, "  "])

      assert statuses == %{
               "A@Fixture.ORG" => %{status: "not_sure", reason: "smtp_disabled", level: "mx"},
               "junk" => %{status: "invalid", reason: "syntax", level: "syntax"}
             }
    end

    test "agrees with results_for/1 and does not need the step logs" do
      emails = ["a@fixture.org", "b@fixture.org", "never@fixture.org"]
      for email <- emails, do: verify(email)

      from_results =
        Map.new(Verification.results_for(emails), fn {email, r} ->
          {email, Map.take(r, [:status, :reason, :level])}
        end)

      assert Verification.statuses_for(emails) == from_results
      assert from_results |> Map.values() |> Enum.all?(&(map_size(&1) == 3))
    end

    test "empty and unstorable input" do
      assert Verification.statuses_for([]) == %{}
      assert Verification.statuses_for([nil, <<0xFF>>, "a\0b@x.org", 5]) == %{}
    end

    test "a listed-twice address is one key" do
      verify("a@fixture.org")
      assert map_size(Verification.statuses_for(["a@fixture.org", "a@fixture.org"])) == 1
    end
  end

  describe "a stored disposable verdict follows the current setting" do
    setup do
      verify("john@mailinator.com")
      :ok
    end

    defp disposable_status(value),
      do:
        Settings.update_setting_with_module(
          "email_verify_disposable_status",
          value,
          "email_system"
        )

    test "a disposable verdict is a temp one, yet it is served from the cache" do
      assert {:ok, %Result{status: "temp", reason: "disposable", source: "cache"}} =
               verify("john@mailinator.com")
    end

    test "temp by default" do
      assert %{"john@mailinator.com" => %{status: "temp", reason: "disposable"}} =
               Verification.statuses_for(["john@mailinator.com"])
    end

    test "results_for, statuses_for, summary and a cached verify all re-map it" do
      disposable_status("invalid")
      email = "john@mailinator.com"

      assert %{^email => %Result{status: "invalid", reason: "disposable"}} =
               Verification.results_for([email])

      assert %{^email => %{status: "invalid"}} = Verification.statuses_for([email])
      assert %{invalid: 1, temp: 0} = Verification.summary([email])
      assert {:ok, %Result{status: "invalid", source: "cache"}} = verify(email)
    end

    test "a verdict stored as invalid comes back temp when the setting is back to temp" do
      disposable_status("invalid")
      verify("jane@mailinator.com", force: true)

      assert %{status: "invalid"} =
               Verification.statuses_for(["jane@mailinator.com"])["jane@mailinator.com"]

      disposable_status("temp")

      assert %{status: "temp"} =
               Verification.statuses_for(["jane@mailinator.com"])["jane@mailinator.com"]

      assert {:ok, %Result{status: "temp"}} = verify("jane@mailinator.com")
    end

    test "other reasons are left alone" do
      disposable_status("invalid")
      verify("a@fixture.org")
      assert %{status: "not_sure"} = Verification.statuses_for(["a@fixture.org"])["a@fixture.org"]
    end
  end

  describe "summary/1" do
    test "counts by status; addresses with no verdict are unchecked" do
      FakeResolver.put("dead-fixture.org", mx: {:error, :nxdomain})
      FakeResolver.put("flaky-fixture.org", mx: {:error, :servfail})

      for email <- ["a@fixture.org", "b@fixture.org", "x@dead-fixture.org", "x@flaky-fixture.org"],
          do: verify(email)

      summary =
        Verification.summary([
          "a@fixture.org",
          "b@fixture.org",
          "x@dead-fixture.org",
          "x@flaky-fixture.org",
          "never@fixture.org",
          "never2@fixture.org"
        ])

      assert summary == %{valid: 0, invalid: 1, temp: 1, not_sure: 2, unchecked: 2}
    end

    test "an empty list is all zeroes" do
      assert Verification.summary([]) == %{
               valid: 0,
               invalid: 0,
               temp: 0,
               not_sure: 0,
               unchecked: 0
             }
    end
  end

  # Pretends the stored verdict was made `days` ago.
  defp age(uuid, days: days) do
    past = DateTime.add(PhoenixKit.Utils.Date.utc_now(), -days * 86_400, :second)
    Repo.update_all(from(r in Result, where: r.uuid == ^uuid), set: [checked_at: past])
  end
end
