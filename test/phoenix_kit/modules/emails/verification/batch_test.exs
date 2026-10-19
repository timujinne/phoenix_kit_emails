defmodule PhoenixKit.Modules.Emails.Verification.BatchTest do
  # Not async: the workers read the resolver from the application env (a global),
  # and the Oban instance is a named singleton.
  use PhoenixKitEmails.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitEmails.Test.Repo

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.BatchStartWorker
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @mx {:ok, [%{host: "mx.fixture.org", pref: 10}]}

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    start_supervised!(PhoenixKit.PubSub.Manager)

    original = Application.get_env(:phoenix_kit_emails, :verification_resolver)
    Application.put_env(:phoenix_kit_emails, :verification_resolver, FakeResolver)

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit_emails, :verification_resolver, original),
        else: Application.delete_env(:phoenix_kit_emails, :verification_resolver)
    end)

    FakeResolver.put("fixture.org", mx: @mx)
    :ok
  end

  defp start(emails, opts \\ []) do
    {:ok, batch} = Verification.start_batch(emails, "manual", "ref-1", opts)
    batch
  end

  defp run_start_worker(batch) do
    job =
      Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

    perform_job(BatchStartWorker, job.args)
  end

  defp verify_jobs(batch) do
    all_enqueued(worker: VerifyEmailWorker)
    |> Enum.filter(&(&1.args["batch_uuid"] == batch.uuid))
  end

  defp perform_verify(batch, email, meta \\ %{}) do
    perform_job(VerifyEmailWorker, %{"batch_uuid" => batch.uuid, "email" => email}, meta: meta)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  defp reload(batch), do: Repo.get!(Batch, batch.uuid)
  defp items(batch), do: Repo.all(from(i in BatchItem, where: i.batch_uuid == ^batch.uuid))

  defp set_setting(key, value),
    do: Settings.update_setting_with_module(key, to_string(value), "email_system")

  describe "start_batch/4" do
    test "stores a queued batch with the deduplicated total, and enqueues the start worker" do
      batch =
        start(["John@Fixture.org", " john@fixture.org ", "JOHN@FIXTURE.ORG", "ann@fixture.org"],
          title: "Autumn list"
        )

      assert batch.state == "queued"
      assert batch.total == 2
      assert batch.processed == 0
      assert batch.counts == %{}
      assert batch.source_type == "manual"
      assert batch.source_ref == "ref-1"
      assert batch.title == "Autumn list"

      assert [job] = all_enqueued(worker: BatchStartWorker)
      assert job.args["batch_uuid"] == batch.uuid
      assert job.queue == "email_verification"
      assert job.args["emails"] == ["John@fixture.org", "ann@fixture.org"]

      # Nothing is inserted synchronously: the items are the worker's job.
      assert items(batch) == []
    end

    test "keeps created_by_uuid, accepts a missing source_ref" do
      user = Ecto.UUID.generate()

      {:ok, batch} =
        Verification.start_batch(["a@fixture.org"], "crm_list", nil, created_by_uuid: user)

      assert batch.created_by_uuid == user
      assert batch.source_ref == nil
    end

    test "drops blank, NUL and non-text entries before counting" do
      batch = start(["a@fixture.org", "", "   ", "b@fixture.org\0", <<255, 254>>, nil, 42])
      assert batch.total == 1
    end

    test "an address that is only syntactically wrong is still a member" do
      assert start(["not-an-address", "a@fixture.org"]).total == 2
    end

    test "refuses an unknown source_type and an empty list, and enqueues nothing" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Verification.start_batch(["a@fixture.org"], "bogus", nil)

      assert %{source_type: [_]} = errors_on(changeset)

      assert {:error, :no_emails} = Verification.start_batch(["", nil], "manual", nil)
      assert {:error, :no_emails} = Verification.start_batch([], "manual", nil)

      assert all_enqueued(worker: BatchStartWorker) == []
      assert Repo.aggregate(Batch, :count) == 0
    end

    test "accepts every source type of the spec" do
      for type <-
            ~w(newsletters_crm_list newsletters_user_group crm_list crm_contacts manual) do
        assert {:ok, %Batch{source_type: ^type}} =
                 Verification.start_batch(["a@fixture.org"], type, nil)
      end
    end
  end

  describe "BatchStartWorker" do
    test "inserts the items, marks the batch running, enqueues one verify job per address" do
      batch = start(["a@fixture.org", "b@fixture.org", "c@fixture.org"])

      assert :ok = run_start_worker(batch)

      assert reload(batch).state == "running"
      assert reload(batch).started_at

      assert items(batch) |> Enum.map(&{&1.email, &1.state}) |> Enum.sort() ==
               [
                 {"a@fixture.org", "pending"},
                 {"b@fixture.org", "pending"},
                 {"c@fixture.org", "pending"}
               ]

      jobs = verify_jobs(batch)

      assert jobs |> Enum.map(& &1.args["email"]) |> Enum.sort() ==
               ["a@fixture.org", "b@fixture.org", "c@fixture.org"]

      assert Enum.all?(jobs, &(&1.queue == "email_verification"))
    end

    test "runs twice without duplicating items or jobs" do
      batch = start(["a@fixture.org", "b@fixture.org"])

      assert :ok = run_start_worker(batch)
      assert :ok = run_start_worker(batch)

      assert length(items(batch)) == 2
      assert length(verify_jobs(batch)) == 2
    end

    test "a retry enqueues only the addresses still pending" do
      batch = start(["a@fixture.org", "b@fixture.org"])
      :ok = run_start_worker(batch)
      :ok = perform_verify(batch, "a@fixture.org")

      Repo.delete_all(from(j in Oban.Job, where: j.worker == ^inspect(VerifyEmailWorker)))
      assert :ok = run_start_worker(batch)

      assert verify_jobs(batch) |> Enum.map(& &1.args["email"]) == ["b@fixture.org"]
    end

    test "handles more addresses than one insert chunk" do
      emails = for n <- 1..1_250, do: "user#{n}@fixture.org"
      batch = start(emails)

      assert :ok = run_start_worker(batch)

      assert Repo.aggregate(from(i in BatchItem, where: i.batch_uuid == ^batch.uuid), :count) ==
               1_250

      assert length(verify_jobs(batch)) == 1_250
    end

    test "does nothing for a cancelled batch, and cancels for a missing one" do
      batch = start(["a@fixture.org"])
      {:ok, _} = Verification.cancel_batch(batch.uuid)

      assert {:cancel, :batch_cancelled} =
               perform_job(BatchStartWorker, %{
                 "batch_uuid" => batch.uuid,
                 "emails" => ["a@fixture.org"]
               })

      assert items(batch) == []

      assert {:cancel, :batch_not_found} =
               perform_job(BatchStartWorker, %{
                 "batch_uuid" => Ecto.UUID.generate(),
                 "emails" => ["a@fixture.org"]
               })
    end
  end

  describe "VerifyEmailWorker" do
    setup do
      batch = start(["john@fixture.org", "ann@fixture.org", "broken"])
      :ok = run_start_worker(batch)
      {:ok, batch: batch}
    end

    test "verifies, stores the result, finishes the item and counts it", %{batch: batch} do
      assert :ok = perform_verify(batch, "john@fixture.org")

      assert %Result{status: "not_sure", reason: "smtp_disabled"} =
               Repo.get_by!(Result, email: "john@fixture.org")

      assert Enum.find(items(batch), &(&1.email == "john@fixture.org")).state == "done"

      batch = reload(batch)
      assert batch.processed == 1
      assert batch.counts == %{"not_sure" => 1}
      assert batch.state == "running"
      assert batch.finished_at == nil
    end

    test "counts per status and flips to done with finished_at when processed reaches total",
         %{batch: batch} do
      assert :ok = perform_verify(batch, "john@fixture.org")
      assert :ok = perform_verify(batch, "broken")
      assert reload(batch).state == "running"

      assert :ok = perform_verify(batch, "ann@fixture.org")

      done = reload(batch)
      assert done.state == "done"
      assert done.processed == 3
      assert done.counts == %{"not_sure" => 2, "invalid" => 1}
      assert %DateTime{} = done.finished_at
    end

    test "a job that runs twice counts once", %{batch: batch} do
      assert :ok = perform_verify(batch, "john@fixture.org")
      assert :ok = perform_verify(batch, "john@fixture.org")

      assert reload(batch).processed == 1
    end

    test "uses a fresh stored verdict instead of running the pipeline", %{batch: batch} do
      {:ok, _} = Verification.verify("john@fixture.org", resolver: FakeResolver)
      Process.delete({FakeResolver, :calls})

      assert :ok = perform_verify(batch, "john@fixture.org")

      assert FakeResolver.calls() == []
      assert reload(batch).counts == %{"not_sure" => 1}
    end

    test "broadcasts progress on email_verify:batch:<uuid>, and a final message when done",
         %{batch: batch} do
      :ok = Verification.subscribe_batch(batch.uuid)

      :ok = perform_verify(batch, "john@fixture.org")

      assert_receive {:email_verify_batch,
                      %{
                        uuid: uuid,
                        state: "running",
                        processed: 1,
                        total: 3,
                        counts: %{"not_sure" => 1}
                      }}

      assert uuid == batch.uuid

      :ok = perform_verify(batch, "ann@fixture.org")
      :ok = perform_verify(batch, "broken")

      assert_receive {:email_verify_batch, %{state: "running", processed: 2}}
      assert_receive {:email_verify_batch, %{state: "done", processed: 3, total: 3}}
      refute_receive {:email_verify_batch, _}
    end

    test "the topic is the documented one", %{batch: batch} do
      assert Verification.batch_topic(batch.uuid) == "email_verify:batch:" <> batch.uuid
    end

    test "a cancelled batch is left alone", %{batch: batch} do
      {:ok, _} = Verification.cancel_batch(batch.uuid)

      assert {:cancel, :batch_cancelled} = perform_verify(batch, "john@fixture.org")
      assert reload(batch).processed == 0
      assert Repo.get_by(Result, email: "john@fixture.org") == nil
    end

    test "a missing batch or item cancels the job instead of retrying" do
      assert {:cancel, :batch_not_found} =
               perform_job(VerifyEmailWorker, %{
                 "batch_uuid" => Ecto.UUID.generate(),
                 "email" => "john@fixture.org"
               })
    end

    test "an address that is not a member of the batch is ignored", %{batch: batch} do
      assert {:cancel, :not_a_member} = perform_verify(batch, "stranger@fixture.org")
      assert reload(batch).processed == 0
    end
  end

  describe "retries" do
    setup do
      FakeResolver.put("flaky.org", mx: {:error, :servfail}, addr: {:error, :servfail})
      batch = start(["john@flaky.org", "ann@fixture.org"])
      :ok = run_start_worker(batch)
      {:ok, batch: batch}
    end

    test "a dns_error result snoozes with a growing backoff and does not count", %{batch: batch} do
      assert {:snooze, first} = perform_verify(batch, "john@flaky.org")
      assert {:snooze, second} = perform_verify(batch, "john@flaky.org", %{"snoozed" => 1})
      assert first > 0 and second > first

      assert reload(batch).processed == 0
      item = Enum.find(items(batch), &(&1.email == "john@flaky.org"))
      assert item.state == "pending"
      assert %DateTime{} = item.next_attempt_at
    end

    test "after the maximum of attempts the temp result is kept and counted", %{batch: batch} do
      set_setting("email_verify_dns_max_attempts", 3)

      assert {:snooze, _} = perform_verify(batch, "john@flaky.org", %{"snoozed" => 1})
      assert :ok = perform_verify(batch, "john@flaky.org", %{"snoozed" => 2})

      assert %Result{status: "temp", reason: "dns_error"} =
               Repo.get_by!(Result, email: "john@flaky.org")

      assert reload(batch).counts == %{"temp" => 1}
      item = Enum.find(items(batch), &(&1.email == "john@flaky.org"))
      assert item.state == "done"
      assert item.next_attempt_at == nil
    end

    test "the maximum is a setting; 1 means no retry", %{batch: batch} do
      set_setting("email_verify_dns_max_attempts", 1)
      assert :ok = perform_verify(batch, "john@flaky.org")
      assert reload(batch).counts == %{"temp" => 1}
    end

    test "a non-dns temp result (a disposable domain set to temp) is not retried", %{batch: batch} do
      set_setting("email_verify_disposable_status", "temp")
      {:ok, other} = Verification.start_batch(["x@mailinator.com"], "manual", nil)
      :ok = run_start_worker(other)

      assert :ok = perform_verify(other, "x@mailinator.com")
      assert reload(other).counts == %{"temp" => 1}
      assert reload(batch).processed == 0
    end
  end

  describe "Retry.decide/2 (greylist path, reachable only from SMTP results)" do
    alias PhoenixKit.Modules.Emails.Verification.Retry

    defp temp(reason), do: %Result{status: "temp", reason: reason}

    test "greylist snoozes 15 to 30 minutes by default" do
      for _ <- 1..30 do
        assert {:snooze, seconds} = Retry.decide(temp("greylist"), 0)
        assert seconds in 900..1800
      end
    end

    test "the minimum is a setting and the window is up to double of it" do
      set_setting("email_verify_grey_retry_minutes", 20)

      for _ <- 1..30 do
        assert {:snooze, seconds} = Retry.decide(temp("greylist"), 0)
        assert seconds in 1200..2400
      end
    end

    test "gives up after the maximum of greylist attempts" do
      set_setting("email_verify_grey_max_attempts", 2)

      assert {:snooze, _} = Retry.decide(temp("greylist"), 0)
      assert :done = Retry.decide(temp("greylist"), 1)
    end

    test "everything else is final" do
      assert :done = Retry.decide(%Result{status: "invalid", reason: "no_mx"}, 0)
      assert :done = Retry.decide(%Result{status: "not_sure", reason: "smtp_disabled"}, 0)
      assert :done = Retry.decide(temp("disposable"), 0)
    end
  end

  describe "uniqueness" do
    test "the same batch and address is one incomplete job" do
      batch = start(["a@fixture.org"])
      args = %{"batch_uuid" => batch.uuid, "email" => "a@fixture.org"}

      {:ok, first} = Oban.insert(VerifyEmailWorker.new(args))
      {:ok, second} = Oban.insert(VerifyEmailWorker.new(args))
      assert second.conflict?
      assert second.id == first.id

      assert length(verify_jobs(batch)) == 1

      other = %{args | "email" => "b@fixture.org"}
      {:ok, _} = Oban.insert(VerifyEmailWorker.new(other))
      assert length(verify_jobs(batch)) == 2
    end

    test "queue and retry options" do
      changeset = VerifyEmailWorker.new(%{"batch_uuid" => "x", "email" => "y"})
      assert Ecto.Changeset.get_field(changeset, :queue) == "email_verification"
      assert Ecto.Changeset.get_field(changeset, :max_attempts) > 1
    end
  end

  describe "cancel_batch/1" do
    test "cancels the batch and its pending jobs" do
      batch = start(["a@fixture.org", "b@fixture.org"])
      :ok = run_start_worker(batch)
      assert length(verify_jobs(batch)) == 2

      :ok = Verification.subscribe_batch(batch.uuid)

      assert {:ok, %Batch{state: "cancelled", finished_at: %DateTime{}}} =
               Verification.cancel_batch(batch.uuid)

      assert verify_jobs(batch) == []
      assert reload(batch).state == "cancelled"
      assert_receive {:email_verify_batch, %{state: "cancelled"}}
    end

    test "is idempotent, and refuses a finished or unknown batch" do
      batch = start(["a@fixture.org"])
      :ok = run_start_worker(batch)
      :ok = perform_verify(batch, "a@fixture.org")
      assert reload(batch).state == "done"

      assert {:error, :not_cancellable} = Verification.cancel_batch(batch.uuid)
      assert {:error, :not_found} = Verification.cancel_batch(Ecto.UUID.generate())
      assert {:error, :not_found} = Verification.cancel_batch("not-a-uuid")

      other = start(["b@fixture.org"])
      assert {:ok, %Batch{state: "cancelled"}} = Verification.cancel_batch(other.uuid)
      assert {:ok, %Batch{state: "cancelled"}} = Verification.cancel_batch(other.uuid)
    end
  end

  describe "reading batches" do
    test "get_batch/1" do
      batch = start(["a@fixture.org"])

      assert %Batch{uuid: uuid} = Verification.get_batch(batch.uuid)
      assert uuid == batch.uuid
      assert Verification.get_batch(Ecto.UUID.generate()) == nil
      assert Verification.get_batch("not-a-uuid") == nil
      assert Verification.get_batch(nil) == nil
    end

    test "list_batches/2 is newest first and scoped by source; latest_batch/2 is its head" do
      {:ok, first} = Verification.start_batch(["a@fixture.org"], "crm_list", "list-1")
      {:ok, second} = Verification.start_batch(["a@fixture.org"], "crm_list", "list-1")
      {:ok, _other_ref} = Verification.start_batch(["a@fixture.org"], "crm_list", "list-2")
      {:ok, _other_type} = Verification.start_batch(["a@fixture.org"], "manual", "list-1")
      {:ok, no_ref} = Verification.start_batch(["a@fixture.org"], "crm_contacts", nil)

      assert Verification.list_batches("crm_list", "list-1") |> Enum.map(& &1.uuid) ==
               [second.uuid, first.uuid]

      assert %Batch{uuid: uuid} = Verification.latest_batch("crm_list", "list-1")
      assert uuid == second.uuid

      assert [%Batch{uuid: ref_nil}] = Verification.list_batches("crm_contacts", nil)
      assert ref_nil == no_ref.uuid

      assert Verification.list_batches("crm_list", "nope") == []
      assert Verification.latest_batch("crm_list", "nope") == nil
    end
  end

  describe "the queue" do
    test "the Emails module declares :email_verification with a default limit of 5" do
      assert Keyword.fetch!(Emails.oban_queues(), :email_verification) |> limit() == 5
    end

    test "queue_configured?/0 follows the host's Oban queues, as Emails.Queue.runnable?/0 does" do
      app = PhoenixKit.Config.get_parent_app()
      original = Application.get_env(app, Oban)

      on_exit(fn ->
        if original,
          do: Application.put_env(app, Oban, original),
          else: Application.delete_env(app, Oban)
      end)

      Application.put_env(app, Oban, queues: [default: 10, emails: 5])
      refute Verification.queue_configured?()

      Application.put_env(app, Oban, queues: [email_verification: 5])
      assert Verification.queue_configured?()

      Application.put_env(app, Oban, queues: %{email_verification: 5})
      refute Verification.queue_configured?()

      Application.delete_env(app, Oban)
      refute Verification.queue_configured?()
    end

    defp limit(limit) when is_integer(limit), do: limit
    defp limit(opts) when is_list(opts), do: Keyword.fetch!(opts, :limit)
  end

  describe "end to end" do
    test "draining the queue verifies every address and finishes the batch" do
      FakeResolver.put("other.org", mx: @mx)

      emails = [
        "a@fixture.org",
        "b@fixture.org",
        "c@other.org",
        "dup@fixture.org",
        "DUP@fixture.org",
        "x"
      ]

      batch = start(emails)
      :ok = Verification.subscribe_batch(batch.uuid)

      assert %{success: 6, failure: 0} =
               Oban.drain_queue(queue: :email_verification, with_recursion: true)

      done = reload(batch)
      assert done.total == 5
      assert done.state == "done"
      assert done.processed == 5
      assert done.counts == %{"not_sure" => 4, "invalid" => 1}
      assert Verification.summary(emails).unchecked == 0

      assert_receive {:email_verify_batch, %{state: "done"}}
    end
  end
end
