defmodule PhoenixKit.Modules.Emails.Verification.SmtpQueueTest do
  @moduledoc """
  The queue: queueing and its dedup, claiming sessions (grouping by domain, one live
  lease per domain, the interval, pauses, `not_before`, the probe), taking back
  expired leases, and settling reports (validation, idempotency, foreign leases,
  retries, the domain and runner side effects). No sockets: the mail host's answers
  are data.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Ecto.Query
  import PhoenixKitEmails.Test.SmtpHelpers

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @now ~U[2026-10-20 10:00:00Z]

  # Fixture phrases, not the original tool's lists.
  @phrases %{
    grey: ["fixture grey phrase", "fixture grey other"],
    quota: ["fixture quota phrase"],
    block: ["fixture block phrase"],
    user_unknown: ["user unknown", "5.1.1", "no such user"]
  }

  setup do
    configure_runner_mode()
    %{runner: runner()}
  end

  defp items(domain),
    do: Repo.all(from(i in Item, where: i.domain == ^domain, order_by: i.inserted_at))

  defp item(email), do: Repo.get_by!(Item, email: email)
  defp result(email), do: Repo.get_by!(Result, email: email)
  defp domain_row(domain), do: DomainCache.get(domain)

  defp claim!(runner, max \\ 4, now \\ @now) do
    assert {:ok, sessions} = SmtpQueue.claim(runner, max, now)
    sessions
  end

  describe "enqueue" do
    test "verify with smtp: :enqueue stores the interim verdict and queues the address", _ do
      domain = unique_domain()
      [result] = queue(domain, ["info"])

      assert {result.status, result.reason, result.level} == {"not_sure", "smtp_pending", "mx"}

      assert [%Item{state: "queued", attempts: 0, checked_as: checked, domain: ^domain}] =
               items(domain)

      assert checked == "info@" <> domain
      assert SmtpQueue.live?("info@" <> domain)
    end

    test "the checked address has the +tag cut off, the result keeps it" do
      domain = unique_domain()
      queue(domain, ["john+news"])

      assert %Item{email: email, checked_as: checked} = hd(items(domain))
      assert email == "john+news@" <> domain
      assert checked == "john@" <> domain
    end

    test "an address waiting is queued once" do
      domain = unique_domain()
      [result] = queue(domain, ["info"])

      assert {:ok, :already_queued} = SmtpQueue.enqueue(result)
      assert length(items(domain)) == 1
    end

    test "verifying a pending address again does not queue it twice" do
      domain = unique_domain()
      queue(domain, ["info"])

      assert {:ok, %{reason: "smtp_pending"}} =
               Verification.verify("info@" <> domain, smtp: :enqueue)

      assert length(items(domain)) == 1
    end

    test "with the mode off nothing is queued" do
      put("email_verify_smtp_mode", "off")
      domain = unique_domain()
      [result] = queue(domain, ["info"])

      assert result.reason == "smtp_disabled"
      assert items(domain) == []
    end

    test "without the option a synchronous verify queues nothing" do
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 1}]})

      assert {:ok, %{reason: "smtp_disabled"}} = Verification.verify("info@" <> domain)
      assert items(domain) == []
    end

    test "a finished address can be queued again" do
      domain = unique_domain()
      [result] = queue(domain, ["info"])
      Repo.update_all(from(i in Item, where: i.domain == ^domain), set: [state: "done"])

      assert {:ok, :queued} = SmtpQueue.enqueue(result)
      assert length(items(domain)) == 2
    end

    test "a stored pending verdict is not final unless the address is still in the queue" do
      domain = unique_domain()
      queue(domain, ["info"])

      assert {:ok, %{source: "cache", reason: "smtp_pending"}} =
               Verification.verify("info@" <> domain, smtp: :enqueue)

      Repo.update_all(from(i in Item, where: i.domain == ^domain), set: [state: "cancelled"])

      assert {:ok, %{source: "direct", reason: "smtp_pending"}} =
               Verification.verify("info@" <> domain, smtp: :enqueue)

      assert Enum.map(items(domain), & &1.state) |> Enum.sort() == ["cancelled", "queued"]
    end
  end

  describe "claim: lease length" do
    test "a lease setting below the floor still holds the rows for the floor", %{runner: runner} do
      put("email_verify_smtp_lease_s", "30")
      domain = unique_domain()
      queue(domain, ["one"])

      assert [%{domain: ^domain}] = claim!(runner)

      assert Enum.all?(
               items(domain),
               &(DateTime.diff(&1.lease_expires_at, @now) == Config.smtp_lease_floor_s())
             )
    end
  end

  describe "claim: sessions" do
    test "groups the addresses by domain, one session per domain", %{runner: runner} do
      a = unique_domain("a")
      b = unique_domain("b")
      queue(a, ["one", "two", "three"])
      queue(b, ["four", "five"])

      sessions = claim!(runner)

      assert length(sessions) == 2
      by_domain = Map.new(sessions, &{&1.domain, &1})
      assert length(by_domain[a].rcpt) == 3
      assert length(by_domain[b].rcpt) == 2
      assert by_domain[a].mx == ["mx1." <> a, "mx2." <> a]

      assert Enum.map(by_domain[a].rcpt, & &1.email) |> Enum.sort() ==
               Enum.sort(["one@" <> a, "two@" <> a, "three@" <> a])

      for %{lease: lease, domain: domain} <- sessions do
        assert byte_size(lease) >= 24
        assert Enum.all?(items(domain), &(&1.state == "leased" and &1.lease_token == lease))
        assert Enum.all?(items(domain), &(&1.leased_by == runner.uuid))
        assert Enum.all?(items(domain), &(DateTime.diff(&1.lease_expires_at, @now) == 300))
      end

      assert Enum.map(sessions, & &1.lease) |> Enum.uniq() |> length() == 2
    end

    test "a session holds at most rcpt_per_session addresses", %{runner: runner} do
      put("email_verify_rcpt_per_session", "2")
      domain = unique_domain()
      queue(domain, ~w(a b c d e))

      assert [%{rcpt: rcpt}] = claim!(runner)
      assert length(rcpt) == 2
      assert Enum.count(items(domain), &(&1.state == "queued")) == 3
    end

    test "the oldest waiting address goes first" do
      domain = unique_domain()
      queue(domain, ~w(first second third))
      base = ~U[2026-10-20 09:00:00Z]

      for {local, offset} <- [{"first", 0}, {"second", 1}, {"third", 2}] do
        Repo.update_all(from(i in Item, where: i.email == ^(local <> "@" <> domain)),
          set: [inserted_at: DateTime.add(base, offset)]
        )
      end

      put("email_verify_rcpt_per_session", "2")
      assert [%{rcpt: rcpt}] = claim!(runner())
      assert Enum.map(rcpt, & &1.email) == ["first@" <> domain, "second@" <> domain]
    end

    test "only one session per domain at a time, site-wide", %{runner: runner} do
      put("email_verify_rcpt_per_session", "2")
      domain = unique_domain()
      other = unique_domain()
      queue(domain, ~w(a b c d))
      queue(other, ~w(x))

      first = claim!(runner)
      assert Enum.sort(Enum.map(first, & &1.domain)) == Enum.sort([domain, other])

      # Another runner, any time later: the domain is held, so nothing for it.
      second_runner = runner()
      assert {:ok, []} = SmtpQueue.claim(second_runner, 4, DateTime.add(@now, 60))
      assert Enum.count(items(domain), &(&1.state == "queued")) == 2
    end

    test "a domain is handed out again only after the interval since its last session", %{
      runner: runner
    } do
      put("email_verify_rcpt_per_session", "1")
      domain = unique_domain()
      queue(domain, ~w(a b))

      [session] = claim!(runner)
      report!(runner, session, %{0 => {250, "ok"}}, probe: {550, "no such user"})

      # Eight seconds later: too early. Eleven: fine.
      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 8))
      assert {:ok, [%{domain: ^domain}]} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 11))
    end

    test "the interval is a setting", %{runner: runner} do
      put("email_verify_rcpt_per_session", "1")
      put("email_verify_domain_interval_s", "60")
      domain = unique_domain()
      queue(domain, ~w(a b))

      [session] = claim!(runner)
      report!(runner, session, %{0 => {250, "ok"}}, probe: {550, "no such user"})

      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 59))
      assert {:ok, [_]} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 61))
    end

    test "a paused domain is skipped until the pause ends", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))

      Repo.insert!(
        %DomainCache{domain: domain, paused_until: DateTime.add(@now, 600), blocks: %{}},
        on_conflict: {:replace, [:paused_until]},
        conflict_target: :domain
      )

      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)
      assert {:ok, [%{domain: ^domain}]} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 601))
    end

    test "not_before keeps a retry waiting", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))

      Repo.update_all(from(i in Item, where: i.domain == ^domain),
        set: [not_before: DateTime.add(@now, 300)]
      )

      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)
      assert {:ok, [_]} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 301))
    end

    test "cancelled and finished rows are never handed out", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a b))

      Repo.update_all(from(i in Item, where: i.email == ^("a@" <> domain)),
        set: [state: "cancelled"]
      )

      Repo.update_all(from(i in Item, where: i.email == ^("b@" <> domain)), set: [state: "done"])

      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)
    end

    test "max_sessions bounds the answer; zero is a plain heartbeat", %{runner: runner} do
      for _ <- 1..3, do: queue(unique_domain(), ~w(a))

      assert {:ok, []} = SmtpQueue.claim(runner, 0, @now)
      assert length(claim!(runner, 2)) == 2
    end

    test "nothing is handed out while there is no MAIL FROM", %{runner: runner} do
      put("from_email", "noreply@localhost")
      queue(unique_domain(), ~w(a))

      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)
      assert Repo.aggregate(from(i in Item, where: i.state == "queued"), :count) == 1

      put("email_verify_smtp_mail_from", "verify@acme-mail.test")
      assert [_] = claim!(runner)
    end

    test "a paused runner gets the reason and nothing else", %{runner: runner} do
      queue(unique_domain(), ~w(a))

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [paused_until: DateTime.add(@now, 600), pause_reason: "port 25 closed"]
      )

      runner = Repo.get!(Runner, runner.uuid)
      assert {:paused, "port 25 closed"} = SmtpQueue.claim(runner, 4, @now)
      assert Repo.aggregate(from(i in Item, where: i.state == "queued"), :count) == 1

      assert {:ok, [_]} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 601))
    end

    test "the MX comes from the cache; an expired one is asked again", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))

      Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
        set: [mx_checked_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)]
      )

      FakeResolver.put(domain, mx: {:ok, [%{host: "new-mx." <> domain, pref: 5}]})

      assert [%{mx: ["new-mx." <> _]}] = claim!(runner, 4, DateTime.utc_now())
    end

    test "a domain that lost its mail host is settled invalid / no_mx", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))

      Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
        set: [mx_checked_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)]
      )

      FakeResolver.put(domain, mx: {:error, :nxdomain})

      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.utc_now())
      assert %Result{status: "invalid", reason: "no_mx", level: "mx"} = result("a@" <> domain)
      assert item("a@" <> domain).state == "done"
    end

    test "a DNS failure leaves the address queued for the next claim", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))

      Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
        set: [mx_checked_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)]
      )

      FakeResolver.put(domain, mx: {:error, :timeout})

      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.utc_now())
      assert item("a@" <> domain).state == "queued"
    end

    test "a dead domain with more rows than one chunk is settled a chunk at a time", %{
      runner: runner
    } do
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:error, :nxdomain})

      rows =
        for n <- 1..250 do
          email = "u#{n}@" <> domain
          %{email: email, checked_as: email, domain: domain}
        end

      Repo.insert_all(Item, rows)
      count_chunks()

      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.utc_now())

      # 200 rows, 50 rows, nothing left: one transaction each, not one for the lot.
      assert chunks() == 3

      assert Repo.aggregate(
               from(i in Item, where: i.domain == ^domain and i.state == "done"),
               :count
             ) ==
               250

      assert Repo.aggregate(
               from(r in Result, where: r.domain == ^domain and r.reason == "no_mx"),
               :count
             ) ==
               250
    end
  end

  # Counts the statements that take a chunk of queued rows of a domain under lock.
  defp count_chunks do
    test = self()
    id = {:chunks, make_ref()}

    :telemetry.attach(
      id,
      [:phoenix_kit_emails, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta.query =~ "FOR UPDATE SKIP LOCKED" and
             meta.query =~ "\"domain\" = $1",
           do: send(test, :chunk)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp chunks(count \\ 0) do
    receive do
      :chunk -> chunks(count + 1)
    after
      0 -> count
    end
  end

  describe "claim: the DNS budget" do
    # Domains whose cached MX has run out and whose resolver is slow and dead.
    defp stale_domains(count, prefix) do
      for n <- 1..count do
        domain = unique_domain(prefix)
        queue(domain, ~w(a))

        Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
          set: [mx_checked_at: DateTime.add(DateTime.utc_now(), -30 * 86_400)]
        )

        Repo.update_all(from(i in Item, where: i.domain == ^domain),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -3_600 + n, :second)]
        )

        FakeResolver.put(domain,
          mx: fn ->
            Process.sleep(200)
            {:error, :timeout}
          end
        )

        domain
      end
    end

    test "a claim stops asking DNS once the budget is spent and leaves the rest queued", %{
      runner: runner
    } do
      put("email_verify_smtp_claim_dns_budget_ms", "500")
      domains = stale_domains(8, "slow")
      before = length(FakeResolver.calls())

      {micros, {:ok, []}} =
        :timer.tc(fn -> SmtpQueue.claim(runner, 8, DateTime.utc_now()) end)

      asked = length(FakeResolver.calls()) - before
      assert asked in 1..5
      assert micros < 1_500_000
      assert Enum.all?(domains, &(hd(items(&1)).state == "queued"))
    end

    test "domains whose MX is cached are still leased after the budget is spent", %{
      runner: runner
    } do
      put("email_verify_smtp_claim_dns_budget_ms", "100")
      stale_domains(3, "slow")
      fresh = unique_domain("fresh")
      queue(fresh, ~w(a))

      assert {:ok, [%{domain: ^fresh}]} = SmtpQueue.claim(runner, 8, DateTime.utc_now())
    end
  end

  describe "claim: the catch-all probe" do
    test "is a random address at the domain while the fact is unknown", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(info))

      [session] = claim!(runner)
      assert "x" <> rest = session.probe
      assert [local, ^domain] = String.split(session.probe, "@")
      assert String.length(local) == 10
      refute rest =~ "info"
    end

    test "is different for every session", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      [first] = claim!(runner)
      SmtpQueue.report(runner, [failed_report(first)], @now)

      [second] = claim!(runner, 4, DateTime.add(@now, 400))
      assert is_binary(first.probe) and is_binary(second.probe)
      refute first.probe == second.probe
    end

    test "is absent while the cached fact is fresh, present again once it expires", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(a b))

      Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
        set: [catch_all: false, catch_all_checked_at: @now]
      )

      put("email_verify_rcpt_per_session", "1")
      [fresh] = claim!(runner, 4, DateTime.add(@now, 3600))
      assert fresh.probe == nil

      report!(runner, fresh, %{0 => {550, "no such user"}})

      [stale] = claim!(runner, 4, DateTime.add(@now, 8 * 86_400))
      assert is_binary(stale.probe)
    end

    test "is never made for a free mail provider or a disposable domain", %{runner: runner} do
      for domain <- ["gmail.com", "mailinator.com"] do
        queue_row(domain, "someone")
      end

      sessions = claim!(runner)
      assert Enum.map(sessions, & &1.domain) |> Enum.sort() == ["gmail.com", "mailinator.com"]
      assert Enum.all?(sessions, &is_nil(&1.probe))
    end
  end

  describe "lease expiry" do
    test "an unreported session is taken back with attempts + 1, and can be leased again", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(a))
      [first] = claim!(runner)

      later = DateTime.add(@now, 301)
      assert 1 = SmtpQueue.expire_leases(later)

      assert %Item{state: "queued", attempts: 1, lease_expiries: 1, last_reason: "lease_expired"} =
               row = hd(items(domain))

      # The token stays, so a late report can still find the row.
      assert row.lease_token == first.lease

      [second] = claim!(runner, 4, later)
      refute second.lease == first.lease
      assert hd(items(domain)).lease_token == second.lease
    end

    test "lease expiries are counted apart from greylist and transport retries", %{
      runner: runner
    } do
      put("email_verify_smtp_max_attempts", "2")
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      claim!(runner)
      SmtpQueue.expire_leases(DateTime.add(@now, 301))
      assert %Item{lease_expiries: 1, grey_attempts: 0, transport_attempts: 0} = hd(items(domain))

      t2 = DateTime.add(@now, 400)
      [s2] = claim!(runner, 4, t2)
      report!(runner, s2, %{0 => {451, "fixture grey phrase"}}, now: t2)
      assert %Item{state: "queued", lease_expiries: 1, grey_attempts: 1} = hd(items(domain))

      t3 = DateTime.add(t2, 20 * 60 + 5)
      claim!(runner, 4, t3)
      SmtpQueue.expire_leases(DateTime.add(t3, 301))

      assert %Item{state: "done", attempts: 3, lease_expiries: 2, grey_attempts: 1} =
               hd(items(domain))

      assert %Result{reason: "smtp_unavailable"} = result("a@" <> domain)
    end

    test "any claim sweeps expired leases first", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      claim!(runner)

      assert [%{domain: ^domain}] = claim!(runner, 4, DateTime.add(@now, 400))
    end

    test "after max attempts the address is not_sure / smtp_unavailable", %{runner: runner} do
      put("email_verify_smtp_max_attempts", "2")
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      claim!(runner)
      SmtpQueue.expire_leases(DateTime.add(@now, 301))
      claim!(runner, 4, DateTime.add(@now, 302))
      SmtpQueue.expire_leases(DateTime.add(@now, 700))

      assert %Item{state: "done", attempts: 2, last_reason: "smtp_unavailable"} =
               hd(items(domain))

      assert %Result{status: "not_sure", reason: "smtp_unavailable", level: "mx"} =
               result("a@" <> domain)
    end

    test "a live lease is left alone", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      claim!(runner)

      assert 0 = SmtpQueue.expire_leases(DateTime.add(@now, 299))
      assert hd(items(domain)).state == "leased"
    end
  end

  describe "expire_stale" do
    defp age(domain, local, hours) do
      Repo.update_all(from(i in Item, where: i.email == ^(local <> "@" <> domain)),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)]
      )
    end

    test "settles a row queued longer than the maximum age and finishes its batch" do
      domain = unique_domain()
      queue(domain, ~w(old young))
      age(domain, "old", 49)
      age(domain, "young", 47)
      batch_uuid = awaiting_batch("old@" <> domain)

      assert 1 = SmtpQueue.expire_stale(DateTime.utc_now())

      assert item("old@" <> domain).state == "done"
      assert %Result{status: "not_sure", reason: "smtp_unavailable"} = result("old@" <> domain)
      assert item("young@" <> domain).state == "queued"

      batch = Verification.get_batch(batch_uuid)
      assert {batch.state, batch.processed, batch.awaiting_smtp} == {"done", 1, 0}
      assert batch.counts == %{"not_sure" => 1}
    end

    test "the maximum age is a setting" do
      put("email_verify_smtp_queue_max_age_h", "2")
      domain = unique_domain()
      queue(domain, ~w(a b))
      age(domain, "a", 3)
      age(domain, "b", 1)

      assert 1 = SmtpQueue.expire_stale(DateTime.utc_now())
      assert item("a@" <> domain).state == "done"
      assert item("b@" <> domain).state == "queued"
    end

    test "a row a runner holds is left alone", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [_session] = claim!(runner, 4, DateTime.utc_now())
      age(domain, "a", 100)

      assert 0 = SmtpQueue.expire_stale(DateTime.utc_now())
      assert item("a@" <> domain).state == "leased"
    end

    test "settles more rows than one chunk" do
      domain = unique_domain()

      old = DateTime.add(DateTime.utc_now(), -100 * 3_600, :second) |> DateTime.truncate(:second)

      rows =
        for n <- 1..250 do
          email = "u#{n}@" <> domain
          %{email: email, checked_as: email, domain: domain, inserted_at: old, updated_at: old}
        end

      Repo.insert_all(Item, rows)

      assert 250 = SmtpQueue.expire_stale(DateTime.utc_now())
    end
  end

  describe "repair_stranded" do
    test "finishes an item whose address has a final verdict and no live row" do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      batch_uuid = awaiting_batch(email)

      # The queue row was settled in a report that did not see the parked item.
      :ok =
        Verification.record_smtp_result(
          email,
          %{status: "valid", reason: "smtp_ok", level: "smtp", catch_all: false},
          %{},
          @now
        )

      Repo.update_all(from(i in Item, where: i.email == ^email), set: [state: "done"])
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert 1 = SmtpQueue.repair_stranded(later)

      batch = Verification.get_batch(batch_uuid)
      assert {batch.state, batch.processed, batch.awaiting_smtp} == {"done", 1, 0}
      assert batch.counts == %{"valid" => 1}
    end

    test "settles an item that waits for a row that is gone as not_sure / smtp_unavailable" do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      batch_uuid = awaiting_batch(email)
      Repo.update_all(from(i in Item, where: i.email == ^email), set: [state: "cancelled"])
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert 1 = SmtpQueue.repair_stranded(later)

      assert %Result{status: "not_sure", reason: "smtp_unavailable"} = result(email)
      assert Verification.get_batch(batch_uuid).state == "done"
    end

    test "leaves an item whose address is still in the queue" do
      domain = unique_domain()
      queue(domain, ~w(a))
      batch_uuid = awaiting_batch("a@" <> domain)
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert 0 = SmtpQueue.repair_stranded(later)
      assert Verification.get_batch(batch_uuid).state == "running"
    end

    test "leaves an item that was parked a moment ago" do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      batch_uuid = awaiting_batch(email)
      Repo.update_all(from(i in Item, where: i.email == ^email), set: [state: "done"])

      assert 0 = SmtpQueue.repair_stranded(DateTime.utc_now())
      assert Verification.get_batch(batch_uuid).state == "running"
    end

    test "leaves an item of a cancelled batch" do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      batch_uuid = awaiting_batch(email)
      {:ok, _} = Verification.cancel_batch(batch_uuid)
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert 0 = SmtpQueue.repair_stranded(later)
    end
  end

  describe "report: verdicts" do
    test "a mailbox the host accepts, on a domain the probe proved not catch-all, is valid", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(info))
      [session] = claim!(runner)

      assert {:ok, %{accepted: 1, ignored: 0, rejected: 0, settled: 1}} =
               report!(runner, session, %{0 => {250, "2.1.5 Ok"}},
                 probe: {550, "5.1.1 no such user"}
               )

      assert %Result{status: "valid", reason: "smtp_ok", level: "smtp", catch_all: false} =
               result("info@" <> domain)

      assert %Item{state: "done", last_reason: "smtp_ok", lease_token: nil} = hd(items(domain))

      row = domain_row(domain)
      assert row.catch_all == false
      assert row.catch_all_checked_at == @now
      assert row.last_smtp_at == @now
    end

    test "the stored verdict keeps the pipeline's steps and gains the session's", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(info))
      [session] = claim!(runner)
      report!(runner, session, %{0 => {250, "2.1.5 Ok"}}, probe: {550, "no such user"})

      log = result("info@" <> domain).log
      assert Enum.map(log, & &1["step"]) |> Enum.take(2) == ["normalize", "syntax"]

      assert %{"step" => "smtp_session", "outcome" => "smtp_ok", "mx" => mx, "code" => 250} =
               List.last(log)

      assert mx == "mx1." <> domain
    end

    test "a probe the host accepts makes the domain catch-all: not_sure / catch_all", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(info))
      [session] = claim!(runner)
      report!(runner, session, %{0 => {250, "ok"}}, probe: {250, "ok"})

      assert %Result{status: "not_sure", reason: "catch_all", level: "smtp", catch_all: true} =
               result("info@" <> domain)

      assert domain_row(domain).catch_all == true
    end

    test "a refused mailbox is invalid / mailbox_unknown", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(gone))
      [session] = claim!(runner)

      report!(runner, session, %{0 => {550, "5.1.1 user unknown"}},
        probe: {550, "5.1.1 user unknown"}
      )

      assert %Result{status: "invalid", reason: "mailbox_unknown", level: "smtp"} =
               result("gone@" <> domain)
    end

    test "a cached catch-all fact is used when no probe was made", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(info))

      Repo.update_all(from(d in DomainCache, where: d.domain == ^domain),
        set: [catch_all: true, catch_all_checked_at: DateTime.utc_now()]
      )

      [session] = claim!(runner, 4, DateTime.utc_now())
      assert session.probe == nil
      report!(runner, session, %{0 => {250, "ok"}})

      assert %Result{status: "not_sure", reason: "catch_all"} = result("info@" <> domain)
    end

    test "a free provider is never catch-all without a probe", %{runner: runner} do
      queue_row("gmail.com", "someone")
      [session] = claim!(runner)
      report!(runner, session, %{0 => {250, "2.1.5 OK"}})

      assert %Result{status: "valid", reason: "smtp_ok"} = result("someone@gmail.com")
    end

    test "each address of a session gets its own verdict", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(ok gone full))
      [session] = claim!(runner)

      by_email = Map.new(session.rcpt, &{&1.email, &1.id})

      replies = %{
        by_email["ok@" <> domain] => {250, "ok"},
        by_email["gone@" <> domain] => {550, "5.1.1 user unknown"},
        by_email["full@" <> domain] => {552, "fixture quota phrase"}
      }

      report!(runner, session, replies, probe: {550, "no such user"})

      assert result("ok@" <> domain).status == "valid"
      assert result("gone@" <> domain).reason == "mailbox_unknown"

      assert result("full@" <> domain) |> Map.take([:status, :reason]) == %{
               status: "temp",
               reason: "mailbox_full"
             }
    end

    test "a rejected sender is not_sure / mail_from_rejected for everyone", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a b))
      [session] = claim!(runner)

      steps = [
        %{"cmd" => "banner", "code" => 220, "text" => "hi"},
        %{"cmd" => "ehlo", "code" => 250, "text" => "hi"},
        %{"cmd" => "mail", "code" => 553, "text" => "sender rejected"}
      ]

      report!(runner, session, %{}, steps: steps)

      for local <- ~w(a b) do
        assert %Result{status: "not_sure", reason: "mail_from_rejected"} =
                 result(local <> "@" <> domain)
      end
    end
  end

  describe "report: retries" do
    test "a greylisted address waits grey_retry_minutes and is tried again", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      report!(runner, session, %{0 => {451, "4.7.1 fixture grey phrase"}},
        probe: {550, "no such user"}
      )

      assert %Item{state: "queued", attempts: 1, last_reason: "greylisted"} =
               row = hd(items(domain))

      assert DateTime.diff(row.not_before, @now) == 20 * 60
      assert result("a@" <> domain).reason == "smtp_pending"

      grey = domain_row(domain)
      assert grey.grey_message =~ "fixture grey phrase"
      assert grey.grey_at == @now

      assert {:ok, []} = SmtpQueue.claim(runner, 4, DateTime.add(@now, 20 * 60 - 1))
      assert [%{domain: ^domain}] = claim!(runner, 4, DateTime.add(@now, 20 * 60 + 1))
    end

    test "after max_grey_attempts the verdict is temp / greylisted", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      for attempt <- 1..3 do
        now = DateTime.add(@now, attempt * 3600)
        [session] = claim!(runner, 4, now)
        report!(runner, session, %{0 => {451, "fixture grey phrase"}}, now: now)
      end

      assert %Item{state: "done", attempts: 3} = hd(items(domain))
      assert %Result{status: "temp", reason: "greylisted", level: "smtp"} = result("a@" <> domain)
    end

    test "a refused connection is retried after one minute, then five, then given up", %{
      runner: runner
    } do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      [s1] = claim!(runner)
      SmtpQueue.report(runner, [failed_report(s1)], @now)
      assert DateTime.diff(hd(items(domain)).not_before, @now) == 60

      t2 = DateTime.add(@now, 61)
      [s2] = claim!(runner, 4, t2)
      SmtpQueue.report(runner, [failed_report(s2)], t2)
      assert DateTime.diff(hd(items(domain)).not_before, t2) == 300

      t3 = DateTime.add(t2, 301)
      [s3] = claim!(runner, 4, t3)
      SmtpQueue.report(runner, [failed_report(s3)], t3)

      assert %Item{state: "done"} = hd(items(domain))

      assert %Result{status: "not_sure", reason: "smtp_connect_failed", level: "mx"} =
               result("a@" <> domain)
    end

    test "greylist and transport retries run on their own counters", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      # Two greylist answers, then a refused connection: still the first transport
      # retry (one minute), not the third.
      [s1] = claim!(runner)
      report!(runner, s1, %{0 => {451, "fixture grey phrase"}})
      t2 = DateTime.add(@now, 20 * 60 + 5)
      [s2] = claim!(runner, 4, t2)
      report!(runner, s2, %{0 => {451, "fixture grey phrase"}}, now: t2)
      t3 = DateTime.add(t2, 20 * 60 + 5)
      [s3] = claim!(runner, 4, t3)
      SmtpQueue.report(runner, [failed_report(s3)], t3)

      assert %Item{state: "queued", attempts: 3, grey_attempts: 2, transport_attempts: 1} =
               row = hd(items(domain))

      assert DateTime.diff(row.not_before, t3) == 60
    end

    test "a refused connection does not use up the greylist attempts", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      [s1] = claim!(runner)
      SmtpQueue.report(runner, [failed_report(s1)], @now)
      t2 = DateTime.add(@now, 61)
      [s2] = claim!(runner, 4, t2)
      SmtpQueue.report(runner, [failed_report(s2)], t2)
      assert %Item{state: "queued", transport_attempts: 2} = hd(items(domain))

      # Three greylist answers are still needed to give up.
      Enum.reduce(1..3, DateTime.add(t2, 301), fn attempt, now ->
        [session] = claim!(runner, 4, now)
        report!(runner, session, %{0 => {451, "fixture grey phrase"}}, now: now)
        assert hd(items(domain)).grey_attempts == attempt
        DateTime.add(now, 20 * 60 + 5)
      end)

      assert %Item{state: "done", attempts: 5} = hd(items(domain))
      assert %Result{status: "temp", reason: "greylisted"} = result("a@" <> domain)
    end

    test "a timeout and a reset have their own final reason", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")

      for {outcome, reason} <- [{"timeout", "smtp_timeout"}, {"reset", "smtp_reset"}] do
        domain = unique_domain()
        queue(domain, ~w(a))

        Enum.reduce(0..2, @now, fn _, now ->
          now = DateTime.add(now, 400)
          [session] = claim!(runner, 4, now)
          SmtpQueue.report(runner, [failed_report(session, outcome)], now)
          now
        end)

        assert result("a@" <> domain).reason == reason
      end
    end
  end

  describe "report: acceptance rules" do
    test "a report with an unknown lease is ignored", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      report = report(%{session | lease: "nonsense"}, %{0 => {250, "ok"}})
      assert {:ok, %{accepted: 0, ignored: 1}} = SmtpQueue.report(runner, [report], @now)
      assert hd(items(domain)).state == "leased"
    end

    test "another runner's lease is ignored", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      other = runner()

      assert {:ok, %{accepted: 0, ignored: 1}} =
               SmtpQueue.report(other, [report(session, %{0 => {250, "ok"}})], @now)

      assert hd(items(domain)).state == "leased"
      assert result("a@" <> domain).reason == "smtp_pending"
    end

    test "a repeated report is harmless", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)
      report = report(session, %{0 => {550, "5.1.1 user unknown"}}, probe: {550, "no such user"})

      assert {:ok, %{accepted: 1, settled: 1}} = SmtpQueue.report(runner, [report], @now)
      before = result("a@" <> domain)

      assert {:ok, %{accepted: 0, ignored: 1, settled: 0}} =
               SmtpQueue.report(runner, [report], @now)

      assert result("a@" <> domain) == before
      assert Repo.get(Runner, runner.uuid).jobs_done == 1
    end

    test "a report for a lease that expired but was not taken back is accepted", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)
      late = DateTime.add(@now, 3600)

      report = report(session, %{0 => {250, "ok"}}, probe: {550, "no such user"})
      assert {:ok, %{accepted: 1}} = SmtpQueue.report(runner, [report], late)
      assert result("a@" <> domain).status == "valid"
    end

    test "a report for a lease already taken back and leased anew is ignored", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [old] = claim!(runner)
      later = DateTime.add(@now, 400)
      [_new] = claim!(runner, 4, later)

      report = report(old, %{0 => {250, "ok"}})
      assert {:ok, %{accepted: 0, ignored: 1}} = SmtpQueue.report(runner, [report], later)
      assert result("a@" <> domain).reason == "smtp_pending"
    end

    test "a late report for a row swept back to the queue and not leased again is accepted", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      batch_uuid = awaiting_batch(email)
      [old] = claim!(runner)
      later = DateTime.add(@now, 400)
      assert 1 = SmtpQueue.expire_leases(later)
      assert hd(items(domain)).state == "queued"

      report = report(old, %{0 => {250, "ok"}}, probe: {550, "no such user"})

      assert {:ok, %{accepted: 1, ignored: 0, settled: 1}} =
               SmtpQueue.report(runner, [report], later)

      assert %Item{state: "done", lease_token: nil} = hd(items(domain))
      assert result(email).status == "valid"
      assert Verification.get_batch(batch_uuid).state == "done"

      # The same report again changes nothing.
      assert {:ok, %{accepted: 0, ignored: 1}} = SmtpQueue.report(runner, [report], later)
      assert Repo.get(Runner, runner.uuid).jobs_done == 1
    end

    test "a late report of another runner for a swept row is ignored", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [old] = claim!(runner)
      later = DateTime.add(@now, 400)
      SmtpQueue.expire_leases(later)

      assert {:ok, %{accepted: 0, ignored: 1}} =
               SmtpQueue.report(runner(), [report(old, %{0 => {250, "ok"}})], later)

      assert hd(items(domain)).state == "queued"
    end

    test "a late report of a row that was cancelled meanwhile is ignored", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      batch_uuid = awaiting_batch("a@" <> domain)
      [old] = claim!(runner)
      later = DateTime.add(@now, 400)
      SmtpQueue.expire_leases(later)
      assert {:ok, _} = Verification.cancel_batch(batch_uuid)
      assert hd(items(domain)).state == "cancelled"

      assert {:ok, %{accepted: 0, ignored: 1}} =
               SmtpQueue.report(runner, [report(old, %{0 => {250, "ok"}})], later)

      assert result("a@" <> domain).reason == "smtp_pending"
    end

    test "a late report that asks for a retry clears the token, so a repeat is ignored", %{
      runner: runner
    } do
      domain = unique_domain()
      queue(domain, ~w(a))
      [old] = claim!(runner)
      later = DateTime.add(@now, 400)
      SmtpQueue.expire_leases(later)

      report = report(old, %{0 => {451, "fixture grey phrase"}}, probe: {550, "x"})
      assert {:ok, %{accepted: 1}} = SmtpQueue.report(runner, [report], later, phrases: @phrases)
      assert %Item{state: "queued", grey_attempts: 1, lease_token: nil} = hd(items(domain))

      assert {:ok, %{accepted: 0, ignored: 1}} =
               SmtpQueue.report(runner, [report], later, phrases: @phrases)

      assert hd(items(domain)).grey_attempts == 1
    end

    test "results of the wrong shape are rejected, the rest are settled", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      good = report(session, %{0 => {550, "5.1.1 user unknown"}})

      bad = [
        %{"lease" => session.lease, "outcome" => "exploded"},
        %{"outcome" => "answered"},
        %{"lease" => session.lease, "outcome" => "answered", "steps" => "banner"},
        %{
          "lease" => session.lease,
          "outcome" => "answered",
          "rcpt" => [%{"id" => "x", "code" => "250"}]
        },
        %{
          "lease" => session.lease,
          "outcome" => "answered",
          "rcpt" => [%{"id" => "x", "code" => 1000}]
        },
        "garbage"
      ]

      assert {:ok, %{accepted: 1, rejected: 6}} = SmtpQueue.report(runner, bad ++ [good], @now)
      assert result("a@" <> domain).reason == "mailbox_unknown"
    end

    test "unknown steps are skipped, a reply for an address that is not in the session is ignored",
         %{
           runner: runner
         } do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      report =
        report(session, %{0 => {250, "ok"}},
          steps: [
            %{"cmd" => "banner", "code" => 220, "text" => "hi"},
            %{"cmd" => "starttls", "code" => 220, "text" => "go"},
            %{"cmd" => "rcpt_probe", "code" => 550, "text" => "no such user"}
          ]
        )

      report =
        Map.update!(
          report,
          "rcpt",
          &(&1 ++ [%{"id" => Ecto.UUID.generate(), "code" => 250, "text" => "stray"}])
        )

      assert {:ok, %{accepted: 1, settled: 1}} = SmtpQueue.report(runner, [report], @now)
      assert result("a@" <> domain).status == "valid"
    end

    test "reply texts are cut to 512 characters", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      [session] = claim!(runner)

      long = String.duplicate("try later ", 300)
      report!(runner, session, %{0 => {451, long}})

      assert String.length(domain_row(domain).grey_message) == 512
    end

    test "a session may carry several results in one report", %{runner: runner} do
      a = unique_domain()
      b = unique_domain()
      queue(a, ~w(x))
      queue(b, ~w(y))
      sessions = claim!(runner)

      reports = Enum.map(sessions, &report(&1, %{0 => {550, "5.1.1 user unknown"}}))
      assert {:ok, %{accepted: 2, settled: 2}} = SmtpQueue.report(runner, reports, @now)
    end
  end

  describe "report: domain and runner effects" do
    test "two blocks within the hour pause the domain for an hour", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a b))
      put("email_verify_rcpt_per_session", "1")

      [s1] = claim!(runner)
      report!(runner, s1, %{0 => {554, "listed, fixture block phrase"}})
      assert domain_row(domain).paused_until == nil

      t2 = DateTime.add(@now, 5)
      [s2] = claim!(runner, 4, t2)
      report!(runner, s2, %{0 => {554, "listed, fixture block phrase"}}, now: t2)

      row = domain_row(domain)
      assert DateTime.diff(row.paused_until, t2) == 3600
      assert result("a@" <> domain).reason == "smtp_blocked"
    end

    test "blocks outside the window do not add up", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      put("email_verify_rcpt_per_session", "1")
      domain = unique_domain()
      queue(domain, ~w(a b))

      [s1] = claim!(runner)
      report!(runner, s1, %{0 => {554, "listed, fixture block phrase"}})

      t2 = DateTime.add(@now, 2 * 3600)
      [s2] = claim!(runner, 4, t2)
      report!(runner, s2, %{0 => {554, "listed, fixture block phrase"}}, now: t2)

      assert domain_row(domain).paused_until == nil
    end

    test "five failed sessions in a row on three domains pause the runner; clearing resumes it",
         %{
           runner: runner
         } do
      domains = for n <- 1..3, do: unique_domain("r#{n}")
      for d <- domains, do: queue(d, ~w(a b))
      put("email_verify_domain_interval_s", "1")

      # Round one: three refused connections, one per domain. Round two: the retries
      # are due; the fifth failure in all pauses the runner.
      for round <- 1..2 do
        now = DateTime.add(@now, round * 400)
        {:ok, sessions} = SmtpQueue.claim(Repo.get!(Runner, runner.uuid), 20, now)
        assert length(sessions) == 3
        SmtpQueue.report(runner, Enum.map(sessions, &failed_report/1), now)
      end

      paused = Repo.get!(Runner, runner.uuid)
      assert paused.paused_until
      assert paused.pause_reason =~ "5 sessions"
      assert paused.last_error =~ "connect_failed"

      assert {:paused, reason} = SmtpQueue.claim(paused, 4, DateTime.add(@now, 1000))
      assert reason =~ "port 25"

      assert {:ok, 1} = Runners.clear_pause()
      cleared = Repo.get!(Runner, runner.uuid)
      assert cleared.paused_until == nil
      assert cleared.fail_streak == 0
      assert {:ok, _} = SmtpQueue.claim(cleared, 4, DateTime.add(@now, 1000))
    end

    test "failures on fewer than three domains never pause the runner", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      put("email_verify_rcpt_per_session", "1")
      domain = unique_domain()
      queue(domain, ~w(a b c d e f g))

      for i <- 1..7 do
        now = DateTime.add(@now, i * 400)
        {:ok, [session]} = SmtpQueue.claim(Repo.get!(Runner, runner.uuid), 4, now)
        SmtpQueue.report(runner, [failed_report(session)], now)
      end

      runner = Repo.get!(Runner, runner.uuid)
      assert runner.paused_until == nil
      assert runner.fail_streak == 7
      assert runner.fail_domains == [domain]
    end

    test "a clean answer ends the streak", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      put("email_verify_rcpt_per_session", "1")
      a = unique_domain()
      queue(a, ~w(a b c))

      {:ok, [s1]} = SmtpQueue.claim(runner, 4, @now)
      SmtpQueue.report(runner, [failed_report(s1)], @now)
      assert Repo.get!(Runner, runner.uuid).fail_streak == 1

      t = DateTime.add(@now, 400)
      {:ok, [s2]} = SmtpQueue.claim(runner, 4, t)
      SmtpQueue.report(runner, [report(s2, %{0 => {550, "5.1.1 user unknown"}})], t)

      runner = Repo.get!(Runner, runner.uuid)
      assert runner.fail_streak == 0
      assert runner.fail_domains == []
      assert runner.jobs_done == 1
    end

    test "a timeout changes nothing in the streak", %{runner: runner} do
      put("email_verify_domain_interval_s", "1")
      domain = unique_domain()
      queue(domain, ~w(a))

      {:ok, [s1]} = SmtpQueue.claim(runner, 4, @now)
      SmtpQueue.report(runner, [failed_report(s1)], @now)
      t = DateTime.add(@now, 400)
      {:ok, [s2]} = SmtpQueue.claim(runner, 4, t)
      SmtpQueue.report(runner, [failed_report(s2, "timeout")], t)

      assert Repo.get!(Runner, runner.uuid).fail_streak == 1
    end

    test "jobs_done counts settled addresses, not retries", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a b))
      [session] = claim!(runner)

      replies = %{0 => {550, "5.1.1 user unknown"}, 1 => {451, "fixture grey phrase"}}
      report!(runner, session, replies, probe: {550, "x"})

      assert Repo.get!(Runner, runner.uuid).jobs_done == 1
    end
  end

  describe "report: batches" do
    test "settling an address finishes the items awaiting it, in every batch", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain

      batches = for _ <- 1..2, do: awaiting_batch(email)
      [session] = claim!(runner)
      report!(runner, session, %{0 => {550, "5.1.1 user unknown"}}, probe: {550, "x"})

      for batch_uuid <- batches do
        batch = Verification.get_batch(batch_uuid)
        assert {batch.state, batch.processed, batch.awaiting_smtp} == {"done", 1, 0}
        assert batch.counts == %{"invalid" => 1}
      end
    end
  end

  describe "cancelling" do
    test "a cancelled batch takes its queued rows with it", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a b))
      batch_uuid = awaiting_batch("a@" <> domain)

      assert {:ok, _} = Verification.cancel_batch(batch_uuid)

      assert item("a@" <> domain).state == "cancelled"
      assert item("b@" <> domain).state == "queued"
      assert [%{rcpt: [%{email: "b@" <> _}]}] = claim!(runner)
    end

    test "unless another live batch still needs the address" do
      domain = unique_domain()
      queue(domain, ~w(a))
      email = "a@" <> domain
      first = awaiting_batch(email)
      second = awaiting_batch(email)

      assert {:ok, _} = Verification.cancel_batch(first)
      assert item(email).state == "queued"

      assert {:ok, _} = Verification.cancel_batch(second)
      assert item(email).state == "cancelled"
    end

    test "a row a runner holds is left to finish", %{runner: runner} do
      domain = unique_domain()
      queue(domain, ~w(a))
      batch_uuid = awaiting_batch("a@" <> domain)
      [session] = claim!(runner)

      assert {:ok, _} = Verification.cancel_batch(batch_uuid)
      assert item("a@" <> domain).state == "leased"

      report!(runner, session, %{0 => {550, "5.1.1 user unknown"}})
      assert result("a@" <> domain).reason == "mailbox_unknown"
    end
  end

  # --- helpers ---

  defp report!(runner, session, replies, opts \\ []) do
    now = Keyword.get(opts, :now, @now)
    SmtpQueue.report(runner, [report(session, replies, opts)], now, phrases: @phrases)
  end

  # A queued address at a domain that needs no scripted DNS (gmail.com, mailinator.com):
  # the MX is put in the cache directly.
  defp queue_row(domain, local) do
    email = local <> "@" <> domain
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Result{
      email: email,
      domain: domain,
      status: "not_sure",
      reason: "smtp_pending",
      level: "mx",
      log: []
    })

    Repo.insert!(
      %DomainCache{
        domain: domain,
        mx: %{"hosts" => [%{"host" => "mx." <> domain, "pref" => 5}], "implicit" => false},
        has_mx: true,
        mx_checked_at: now,
        blocks: %{}
      },
      on_conflict: :nothing
    )

    {:ok, :queued} = SmtpQueue.enqueue(%Result{email: email})
  end

  # A batch with one item, parked as the worker would park it.
  defp awaiting_batch(email) do
    {:ok, batch} =
      Repo.insert(
        Batch.create_changeset(
          %Batch{},
          %{source_type: "manual", total: 1}
        )
      )

    Repo.update_all(
      from(b in Batch, where: b.uuid == ^batch.uuid),
      set: [state: "running"]
    )

    Repo.insert_all(BatchItem, [
      %{batch_uuid: batch.uuid, email: email}
    ])

    {:ok, :awaiting} =
      Batches.await_smtp(batch.uuid, email)

    batch.uuid
  end
end
