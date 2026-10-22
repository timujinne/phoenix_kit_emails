defmodule PhoenixKit.Modules.Emails.Verification.SmtpRaceTest do
  @moduledoc """
  The one interleaving that needs two real database connections: a runner's report is
  in flight (the queue row is locked, the verdict is written but not committed) while
  the batch job parks the same address. Everything is committed for real here, so the
  rows this test makes are deleted again when it ends.
  """

  # Not async: the pool is switched to auto mode for the length of the test.
  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKitEmails.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    domain = "race#{System.unique_integer([:positive])}.ee"
    email = "a@" <> domain

    on_exit(fn ->
      Repo.delete_all(from(i in BatchItem, where: i.email == ^email))
      Repo.delete_all(from(b in Batch, where: b.source_ref == ^domain))
      Repo.delete_all(from(r in Result, where: r.email == ^email))
      Repo.delete_all(from(i in Item, where: i.email == ^email))
      Sandbox.mode(Repo, :manual)
    end)

    %{email: email, domain: domain}
  end

  test "a worker that parks an address while its report is in flight waits for the verdict", %{
    email: email,
    domain: domain
  } do
    batch =
      Repo.insert!(%Batch{
        source_type: "manual",
        source_ref: domain,
        state: "running",
        total: 1
      })

    Repo.insert!(%BatchItem{batch_uuid: batch.uuid, email: email, state: "pending"})

    Repo.insert!(%Result{
      email: email,
      domain: domain,
      status: "not_sure",
      reason: "smtp_pending",
      level: "mx",
      log: []
    })

    Repo.insert!(%Item{email: email, checked_as: email, domain: domain, state: "leased"})

    test_pid = self()

    # The report: the queue row locked, the verdict written, the batches settled (it
    # sees nothing parked yet) - and then it waits before it commits.
    report =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.all(from(q in Item, where: q.email == ^email, lock: "FOR UPDATE"))
          :ok = Batches.lock_awaiting([email])

          :ok =
            Verification.record_smtp_result(
              email,
              %{status: "valid", reason: "smtp_ok", level: "smtp", catch_all: false},
              %{},
              DateTime.utc_now()
            )

          Repo.update_all(from(q in Item, where: q.email == ^email), set: [state: "done"])
          [] = Batches.settle_awaiting(email, "valid")
          send(test_pid, :report_in_flight)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :report_in_flight, 5_000

    parking = Task.async(fn -> Batches.await_smtp(batch.uuid, email) end)

    assert Task.yield(parking, 300) == nil

    send(report.pid, :commit)
    assert {:ok, :ok} = Task.await(report, 5_000)
    assert {:ok, :settled} = Task.await(parking, 5_000)

    done = Repo.get!(Batch, batch.uuid)
    assert {done.state, done.processed, done.awaiting_smtp} == {"done", 1, 0}
    assert done.counts == %{"valid" => 1}
  end
end
