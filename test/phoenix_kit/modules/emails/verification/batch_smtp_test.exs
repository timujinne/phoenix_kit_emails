defmodule PhoenixKit.Modules.Emails.Verification.BatchSmtpTest do
  @moduledoc """
  Batches with the SMTP mode on: an address that passes the MX step is parked
  (`awaiting_smtp`), counted when its SMTP verdict lands, and the batch is done only
  then; progress shows how many wait. With the mode off nothing changes.
  """

  # Not async: Oban and the PubSub manager are named singletons.
  use PhoenixKitEmails.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitEmails.Test.Repo

  import Ecto.Query
  import PhoenixKitEmails.Test.SmtpHelpers

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.BatchStartWorker
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem
  alias PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @now ~U[2026-10-20 10:00:00Z]

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    start_supervised!(PhoenixKit.PubSub.Manager)
    configure_runner_mode()
    %{runner: runner(), domain: unique_domain()}
  end

  defp start_batch(domain, locals) do
    FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 10}]})
    emails = Enum.map(locals, &(&1 <> "@" <> domain))
    {:ok, batch} = Verification.start_batch(emails, "manual", "smtp-1")

    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

    :ok = perform_job(BatchStartWorker, job.args)

    for email <- emails do
      assert :ok = perform_job(VerifyEmailWorker, verify_args(batch.uuid, email))
    end

    batch
  end

  defp reload(batch), do: Repo.get!(Batch, batch.uuid)

  defp item_states(batch),
    do:
      Repo.all(
        from(i in BatchItem, where: i.batch_uuid == ^batch.uuid, select: {i.email, i.state})
      )
      |> Map.new()

  test "the jobs park the addresses: nothing is processed, the batch stays running", %{
    domain: domain
  } do
    batch = start_batch(domain, ~w(a b c))
    reloaded = reload(batch)

    assert {reloaded.state, reloaded.processed, reloaded.total} == {"running", 0, 3}
    assert reloaded.awaiting_smtp == 3
    assert reloaded.counts == %{}
    assert item_states(batch) |> Map.values() |> Enum.uniq() == ["awaiting_smtp"]

    assert Repo.aggregate(from(r in Result, where: r.reason == "smtp_pending"), :count) == 3
    assert SmtpQueue.counts().queued == 3
  end

  test "each settled address is counted, and the last one finishes the batch", %{
    runner: runner,
    domain: domain
  } do
    put("email_verify_domain_interval_s", "1")
    put("email_verify_rcpt_per_session", "2")
    batch = start_batch(domain, ~w(a b c))
    Batches.subscribe(batch.uuid)

    {:ok, [first]} = SmtpQueue.claim(runner, 4, @now)

    SmtpQueue.report(
      runner,
      [
        report(first, %{0 => {550, "5.1.1 user unknown"}, 1 => {550, "5.1.1 user unknown"}},
          probe: {550, "x"}
        )
      ],
      @now
    )

    mid = reload(batch)
    assert {mid.state, mid.processed, mid.awaiting_smtp} == {"running", 2, 1}
    assert mid.counts == %{"invalid" => 2}
    assert_received {:email_verify_batch, %{processed: 2, awaiting_smtp: 1, state: "running"}}

    later = DateTime.add(@now, 30)
    {:ok, [second]} = SmtpQueue.claim(runner, 4, later)
    SmtpQueue.report(runner, [report(second, %{0 => {250, "ok"}}, probe: {550, "x"})], later)

    done = reload(batch)
    assert {done.state, done.processed, done.awaiting_smtp} == {"done", 3, 0}
    assert done.counts == %{"invalid" => 2, "valid" => 1}
    assert done.finished_at
    assert_received {:email_verify_batch, %{processed: 3, awaiting_smtp: 0, state: "done"}}
    assert item_states(batch) |> Map.values() |> Enum.uniq() == ["done"]
  end

  test "a retry keeps the address awaiting: the batch does not finish", %{
    runner: runner,
    domain: domain
  } do
    batch = start_batch(domain, ~w(a))

    {:ok, [session]} = SmtpQueue.claim(runner, 4, @now)
    SmtpQueue.report(runner, [report(session, %{0 => {451, "fixture grey phrase"}})], @now)

    waiting = reload(batch)
    assert {waiting.state, waiting.processed, waiting.awaiting_smtp} == {"running", 0, 1}
  end

  test "the snapshot broadcast carries awaiting_smtp", %{domain: domain} do
    FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 10}]})
    {:ok, batch} = Verification.start_batch(["a@" <> domain], "manual", nil)
    Batches.subscribe(batch.uuid)

    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

    perform_job(BatchStartWorker, job.args)
    perform_job(VerifyEmailWorker, verify_args(batch.uuid, "a@" <> domain))

    assert_received {:email_verify_batch, %{awaiting_smtp: 1, processed: 0}}
    assert Map.has_key?(Batches.snapshot(reload(batch)), :awaiting_smtp)
  end

  test "a verdict that lands before the job parks the address finishes it on the spot", %{
    domain: domain
  } do
    FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 10}]})
    email = "a@" <> domain
    {:ok, batch} = Verification.start_batch([email], "manual", nil)

    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

    perform_job(BatchStartWorker, job.args)

    # The address is queued, and a fast runner settles it before the job gets to park it.
    {:ok, result} = Verification.verify(email, smtp: :enqueue)

    :ok =
      Verification.record_smtp_result(
        email,
        %{status: "valid", reason: "smtp_ok", level: "smtp", catch_all: false},
        %{},
        @now
      )

    assert result.reason == "smtp_pending"

    assert {:ok, :settled} = Batches.await_smtp(batch.uuid, email)

    done = reload(batch)

    assert {done.state, done.processed, done.awaiting_smtp, done.counts} ==
             {"done", 1, 0, %{"valid" => 1}}
  end

  test "a job that runs again for a parked address does nothing", %{domain: domain} do
    batch = start_batch(domain, ~w(a))
    email = "a@" <> domain

    assert :ok = perform_job(VerifyEmailWorker, verify_args(batch.uuid, email))
    assert reload(batch).awaiting_smtp == 1
  end

  test "a cached final verdict is counted at once, nothing is queued", %{
    runner: runner,
    domain: domain
  } do
    put("email_verify_domain_interval_s", "1")
    first = start_batch(domain, ~w(a))
    {:ok, [session]} = SmtpQueue.claim(runner, 4, @now)

    SmtpQueue.report(
      runner,
      [report(session, %{0 => {550, "5.1.1 user unknown"}}, probe: {550, "x"})],
      @now
    )

    assert reload(first).state == "done"

    {:ok, second} = Verification.start_batch(["a@" <> domain], "manual", "again")

    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == second.uuid))

    perform_job(BatchStartWorker, job.args)

    assert :ok =
             perform_job(VerifyEmailWorker, verify_args(second.uuid, "a@" <> domain))

    again = reload(second)

    assert {again.state, again.processed, again.awaiting_smtp, again.counts} ==
             {"done", 1, 0, %{"invalid" => 1}}

    assert SmtpQueue.counts() == %{queued: 0, leased: 0}
  end

  test "a transient SMTP verdict is not final: a new batch queues the address again", %{
    runner: runner,
    domain: domain
  } do
    put("email_verify_domain_interval_s", "1")
    first = start_batch(domain, ~w(a))
    {:ok, [session]} = SmtpQueue.claim(runner, 4, @now)

    steps = [%{"cmd" => "banner", "code" => 554, "text" => "go away"}]
    SmtpQueue.report(runner, [report(session, %{}, steps: steps)], @now)
    assert %Result{reason: "smtp_blocked"} = Repo.get_by!(Result, email: "a@" <> domain)
    assert reload(first).state == "done"

    second = start_batch(domain, ~w(a))
    assert reload(second).awaiting_smtp == 1
  end

  test "with the mode off the jobs finish the addresses as before", %{domain: domain} do
    put("email_verify_smtp_mode", "off")
    batch = start_batch(domain, ~w(a b))

    done = reload(batch)
    assert {done.state, done.processed, done.awaiting_smtp} == {"done", 2, 0}
    assert done.counts == %{"not_sure" => 2}
    assert SmtpQueue.counts() == %{queued: 0, leased: 0}
  end

  describe "the mode is off while work is queued" do
    setup %{domain: domain} do
      put("email_verify_rcpt_per_session", "2")
      batch = start_batch(domain, ~w(a b c))
      %{batch: batch}
    end

    test "drain_disabled settles queued and leased rows as not_sure / smtp_disabled", %{
      runner: runner,
      domain: domain,
      batch: batch
    } do
      {:ok, [session]} = SmtpQueue.claim(runner, 4, @now)
      assert SmtpQueue.counts() == %{queued: 1, leased: 2}

      put("email_verify_smtp_mode", "off")
      Batches.subscribe(batch.uuid)
      assert SmtpQueue.drain_disabled() == 3

      assert SmtpQueue.counts() == %{queued: 0, leased: 0}

      for local <- ~w(a b c) do
        assert %Result{status: "not_sure", reason: "smtp_disabled", level: "mx"} =
                 Repo.get_by!(Result, email: local <> "@" <> domain)
      end

      done = reload(batch)

      assert {done.state, done.processed, done.awaiting_smtp, done.counts} ==
               {"done", 3, 0, %{"not_sure" => 3}}

      assert item_states(batch) |> Map.values() |> Enum.uniq() == ["done"]
      assert_received {:email_verify_batch, %{processed: 3, state: "done"}}

      # What the runner still holds is ignored when it reports.
      assert {:ok, %{accepted: 0, ignored: 1}} =
               SmtpQueue.report(runner, [report(session, %{0 => {250, "ok"}})], @now)

      assert Repo.get_by!(Result, email: "a@" <> domain).reason == "smtp_disabled"
      assert SmtpQueue.drain_disabled() == 0
    end

    test "claim drains and hands out nothing", %{runner: runner, domain: domain, batch: batch} do
      put("email_verify_smtp_mode", "off")

      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)

      assert SmtpQueue.counts() == %{queued: 0, leased: 0}
      assert reload(batch).state == "done"
      assert Repo.get_by!(Result, email: "b@" <> domain).reason == "smtp_disabled"
    end

    test "runner mode on a core without the machine API is off, and drains", %{
      runner: runner,
      batch: batch
    } do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      assert Config.smtp_mode() == "off"
      assert {:ok, []} = SmtpQueue.claim(runner, 4, @now)
      assert reload(batch).state == "done"
    end

    test "local mode is not drained", %{batch: batch} do
      put("email_verify_smtp_mode", "local")

      assert SmtpQueue.drain_disabled() == 0
      assert SmtpQueue.counts() == %{queued: 3, leased: 0}
      assert reload(batch).state == "running"
    end

    test "runner mode is not drained", %{batch: batch} do
      assert SmtpQueue.drain_disabled() == 0
      assert SmtpQueue.counts() == %{queued: 3, leased: 0}
      assert reload(batch).state == "running"
    end

    test "a batch parked after the drain is finished when the job parks it", %{domain: domain} do
      put("email_verify_smtp_mode", "off")
      SmtpQueue.drain_disabled()

      second = start_batch(domain, ~w(a))
      assert reload(second).state == "done"
    end
  end

  describe "the batches of one address are finished in a stable order" do
    test "settle_awaiting walks them by batch uuid whatever the order of the items", %{
      domain: domain
    } do
      email = "a@" <> domain

      batches =
        for _ <- 1..3 do
          {:ok, batch} =
            Repo.insert(Batch.create_changeset(%Batch{}, %{source_type: "manual", total: 1}))

          Repo.update_all(from(b in Batch, where: b.uuid == ^batch.uuid), set: [state: "running"])
          batch.uuid
        end

      # Items inserted last batch first, so the heap order is not the uuid order.
      for uuid <- Enum.reverse(batches) do
        Repo.insert_all(BatchItem, [%{batch_uuid: uuid, email: email}])
        assert {:ok, :awaiting} = Batches.await_smtp(uuid, email)
      end

      assert Batches.settle_awaiting(email, "valid") == Enum.sort(batches)
    end
  end

  describe "a batch cancelled while its job runs" do
    # The batch is cancelled at the moment the job looks up the MX, after it has
    # checked that the batch is open and before it queues and parks the address.
    defp run_job_cancelled_midway(batch, email, domain) do
      FakeResolver.put(domain,
        mx: fn ->
          {:ok, _} = Verification.cancel_batch(batch.uuid)
          {:ok, [%{host: "mx." <> domain, pref: 10}]}
        end
      )

      perform_job(VerifyEmailWorker, verify_args(batch.uuid, email))
    end

    defp laid_out_batch(domain, locals) do
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 10}]})
      emails = Enum.map(locals, &(&1 <> "@" <> domain))
      {:ok, batch} = Verification.start_batch(emails, "manual", nil)

      job =
        Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

      :ok = perform_job(BatchStartWorker, job.args)
      batch
    end

    test "the address it queued is cancelled, nobody waits for it", %{domain: domain} do
      email = "a@" <> domain
      batch = laid_out_batch(domain, ~w(a))

      assert {:cancel, :batch_cancelled} = run_job_cancelled_midway(batch, email, domain)

      assert %{state: "cancelled"} = Repo.get_by!(SmtpQueueItem, email: email)
      assert SmtpQueue.counts() == %{queued: 0, leased: 0}
    end

    test "unless another live batch still needs the address", %{domain: domain} do
      email = "a@" <> domain
      first = laid_out_batch(domain, ~w(a))
      _second = laid_out_batch(domain, ~w(a))

      assert {:cancel, :batch_cancelled} = run_job_cancelled_midway(first, email, domain)

      assert %{state: "queued"} = Repo.get_by!(SmtpQueueItem, email: email)
    end

    test "a row a runner already holds is left to finish", %{runner: runner, domain: domain} do
      email = "a@" <> domain
      batch = laid_out_batch(domain, ~w(a))

      FakeResolver.put(domain,
        mx: fn ->
          {:ok, _} = Verification.cancel_batch(batch.uuid)
          {:ok, [%{host: "mx." <> domain, pref: 10}]}
        end
      )

      # The row is queued and claimed by a fast runner before the job gets to park it.
      {:ok, _} = Verification.verify(email, smtp: :enqueue)
      {:ok, [_session]} = SmtpQueue.claim(runner, 4, @now)

      assert {:cancel, :batch_cancelled} =
               perform_job(VerifyEmailWorker, verify_args(batch.uuid, email))

      assert %{state: "leased"} = Repo.get_by!(SmtpQueueItem, email: email)
    end
  end

  test "a cancelled batch is turned away by a job that wakes up late", %{domain: domain} do
    FakeResolver.put(domain, mx: {:ok, [%{host: "mx." <> domain, pref: 10}]})
    {:ok, batch} = Verification.start_batch(["a@" <> domain], "manual", nil)

    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

    perform_job(BatchStartWorker, job.args)
    Verification.cancel_batch(batch.uuid)

    assert {:cancel, :batch_cancelled} =
             perform_job(VerifyEmailWorker, verify_args(batch.uuid, "a@" <> domain))
  end
end
