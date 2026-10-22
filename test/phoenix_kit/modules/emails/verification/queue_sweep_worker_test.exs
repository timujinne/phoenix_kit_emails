defmodule PhoenixKit.Modules.Emails.Verification.QueueSweepWorkerTest do
  @moduledoc """
  The sweep that needs no runner: stale queued rows are given up, batch items that
  wait for an address the queue no longer holds are finished, the chain goes on while
  there is something to watch and ends when there is not.
  """

  # Not async: Oban and the PubSub manager are named singletons.
  use PhoenixKitEmails.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitEmails.Test.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import PhoenixKitEmails.Test.SmtpHelpers

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.QueueSweepWorker
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    start_supervised!(PhoenixKit.PubSub.Manager)
    configure_runner_mode()
    %{domain: unique_domain()}
  end

  defp awaiting_batch(email) do
    {:ok, batch} =
      Repo.insert(Batch.create_changeset(%Batch{}, %{source_type: "manual", total: 1}))

    Repo.update_all(from(b in Batch, where: b.uuid == ^batch.uuid), set: [state: "running"])
    Repo.insert_all(BatchItem, [%{batch_uuid: batch.uuid, email: email}])
    {:ok, :awaiting} = Batches.await_smtp(batch.uuid, email)
    batch.uuid
  end

  defp age(email, hours) do
    Repo.update_all(from(i in Item, where: i.email == ^email),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)]
    )
  end

  test "queueing an address starts the sweep chain, once", %{domain: domain} do
    queue(domain, ~w(a b))

    assert [_one] = all_enqueued(worker: QueueSweepWorker)
  end

  test "a run gives up a stale row and finishes the batch waiting for it", %{domain: domain} do
    queue(domain, ~w(a))
    email = "a@" <> domain
    batch_uuid = awaiting_batch(email)
    age(email, 49)
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(QueueSweepWorker, %{})

    assert %Result{status: "not_sure", reason: "smtp_unavailable"} =
             Repo.get_by!(Result, email: email)

    assert Verification.get_batch(batch_uuid).state == "done"
    refute_enqueued(worker: QueueSweepWorker)
  end

  test "the chain goes on while an address is queued", %{domain: domain} do
    queue(domain, ~w(a))
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(QueueSweepWorker, %{})

    assert_enqueued(worker: QueueSweepWorker)
  end

  test "the chain goes on while a batch item awaits the SMTP result, with nothing queued or leased",
       %{domain: domain} do
    queue(domain, ~w(a))
    email = "a@" <> domain
    batch_uuid = awaiting_batch(email)
    Repo.delete_all(Item)
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(QueueSweepWorker, %{})

    assert Repo.get_by!(BatchItem, batch_uuid: batch_uuid, email: email).state == "awaiting_smtp"
    assert_enqueued(worker: QueueSweepWorker)
  end

  test "a sweep that raises is logged and the next run is still scheduled", %{domain: domain} do
    queue(domain, ~w(a))
    Repo.delete_all(Oban.Job)
    Repo.query!("ALTER TABLE phoenix_kit_email_verify_smtp_queue RENAME TO smtp_queue_gone")

    log =
      capture_log(fn ->
        assert :ok = perform_job(QueueSweepWorker, %{})
      end)

    assert log =~ "the SMTP queue sweep failed"
    assert [_one] = all_enqueued(worker: QueueSweepWorker)
  end

  test "with the mode off a run settles what is queued", %{domain: domain} do
    queue(domain, ~w(a))
    put("email_verify_smtp_mode", "off")

    assert :ok = perform_job(QueueSweepWorker, %{})

    assert %Result{reason: "smtp_disabled"} = Repo.get_by!(Result, email: "a@" <> domain)
  end

  test "a run takes back a lease that ran out", %{domain: domain} do
    queue(domain, ~w(a))
    email = "a@" <> domain

    Repo.update_all(from(i in Item, where: i.email == ^email),
      set: [
        state: "leased",
        lease_token: "t",
        leased_by: Ecto.UUID.generate(),
        lease_expires_at: DateTime.add(DateTime.utc_now(), -10, :second)
      ]
    )

    assert :ok = perform_job(QueueSweepWorker, %{})

    assert %Item{state: "queued", lease_expiries: 1} = Repo.get_by!(Item, email: email)
  end
end
