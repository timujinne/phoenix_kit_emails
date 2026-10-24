defmodule PhoenixKit.Modules.Emails.Verification.BatchTest do
  # Not async: the workers read the resolver from the application env (a global),
  # and the Oban instance is a named singleton.
  use PhoenixKitEmails.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitEmails.Test.Repo

  import Ecto.Query
  import PhoenixKitEmails.Test.SmtpHelpers, only: [verify_args: 2]

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
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
    start_supervised!({Phoenix.PubSub, name: :phoenix_kit_internal_pubsub})

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
    perform_job(VerifyEmailWorker, verify_args(batch.uuid, email), meta: meta)
  end

  defp perform_verify_attempt(batch, email, attempt) do
    perform_job(VerifyEmailWorker, verify_args(batch.uuid, email), attempt: attempt)
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
      assert job.args == %{"batch_uuid" => batch.uuid}
      assert job.queue == "email_verification"

      assert items(batch) |> Enum.map(&{&1.email, &1.state}) |> Enum.sort() ==
               [{"John@fixture.org", "pending"}, {"ann@fixture.org", "pending"}]
    end

    test "no address is left in the job table, neither in the start job nor in the verify jobs" do
      batch = start(["secret.person@fixture.org", "other.person@fixture.org"])
      :ok = run_start_worker(batch)

      jobs = Repo.all(from(j in Oban.Job, select: {j.worker, j.args}))
      assert length(jobs) == 3
      refute inspect(jobs) =~ "person"
      refute inspect(jobs) =~ "fixture.org"

      assert Enum.all?(verify_jobs(batch), fn job ->
               Map.keys(job.args) |> Enum.sort() == ["batch_uuid", "item_uuid"]
             end)
    end

    test "a batch of two goes through to done" do
      batch = start(["a@fixture.org", "b@fixture.org"])
      :ok = run_start_worker(batch)

      for job <- verify_jobs(batch), do: assert(:ok = perform_job(VerifyEmailWorker, job.args))

      done = reload(batch)
      assert done.state == "done"
      assert done.processed == 2
      assert done.total == 2
    end

    test "nothing is left behind when the start job cannot be enqueued" do
      stop_supervised!(Oban)

      assert {:error, _reason} = Verification.start_batch(["a@fixture.org"], "manual", nil)
      assert Repo.aggregate(Batch, :count) == 0
      assert Repo.aggregate(BatchItem, :count) == 0
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

    test "accepts every source type the batch knows" do
      for type <-
            ~w(newsletters_crm_list newsletters_user_group crm_list crm_contacts manual) do
        assert {:ok, %Batch{source_type: ^type}} =
                 Verification.start_batch(["a@fixture.org"], type, nil)
      end
    end
  end

  describe "BatchStartWorker" do
    test "marks the batch running and enqueues one verify job per item" do
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

      assert jobs |> Enum.map(& &1.args["item_uuid"]) |> Enum.sort() ==
               items(batch) |> Enum.map(& &1.uuid) |> Enum.sort()

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

      pending = Repo.get_by!(BatchItem, batch_uuid: batch.uuid, email: "b@fixture.org")
      assert verify_jobs(batch) |> Enum.map(& &1.args["item_uuid"]) == [pending.uuid]
    end

    test "a re-run skips an item that already has a job of the earlier shape, with the address in its args" do
      batch = start(["a@fixture.org", "b@fixture.org", "c@fixture.org"])
      :ok = run_start_worker(batch)

      # What the earlier version left queued: a verify job keyed by the address.
      Repo.delete_all(from(j in Oban.Job, where: j.worker == ^inspect(VerifyEmailWorker)))

      {:ok, old_job} =
        %{"batch_uuid" => batch.uuid, "email" => "a@fixture.org"}
        |> VerifyEmailWorker.new()
        |> Oban.insert()

      assert :ok = run_start_worker(batch)

      [item_b, item_c] =
        for email <- ["b@fixture.org", "c@fixture.org"],
            do: Repo.get_by!(BatchItem, batch_uuid: batch.uuid, email: email)

      new_jobs = Enum.reject(verify_jobs(batch), &(&1.id == old_job.id))

      assert new_jobs |> Enum.map(& &1.args["item_uuid"]) |> Enum.sort() ==
               Enum.sort([item_b.uuid, item_c.uuid])

      assert length(verify_jobs(batch)) == 3
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
               perform_job(BatchStartWorker, %{"batch_uuid" => batch.uuid})

      assert verify_jobs(batch) == []

      assert {:cancel, :batch_not_found} =
               perform_job(BatchStartWorker, %{"batch_uuid" => Ecto.UUID.generate()})

      assert {:cancel, :malformed_args} = perform_job(BatchStartWorker, %{"foo" => "bar"})
    end

    test "a job of an earlier version, with the addresses in its args, still lays the batch out" do
      # What the earlier version left behind: a queued batch with no items yet.
      {:ok, batch} =
        Repo.insert(
          Batch.create_changeset(%Batch{}, %{source_type: "manual", total: 2, title: nil})
        )

      args = %{"batch_uuid" => batch.uuid, "emails" => ["a@fixture.org", "b@fixture.org"]}

      assert :ok = perform_job(BatchStartWorker, args)

      assert reload(batch).state == "running"

      assert items(batch) |> Enum.map(& &1.email) |> Enum.sort() == [
               "a@fixture.org",
               "b@fixture.org"
             ]

      assert length(verify_jobs(batch)) == 2

      for job <- verify_jobs(batch), do: assert(:ok = perform_job(VerifyEmailWorker, job.args))
      assert reload(batch).state == "done"
    end

    test "the addresses of an earlier version's job are dropped from the job row once used" do
      {:ok, batch} =
        Repo.insert(
          Batch.create_changeset(%Batch{}, %{source_type: "manual", total: 1, title: nil})
        )

      {:ok, job} =
        %{"batch_uuid" => batch.uuid, "emails" => ["a@fixture.org"]}
        |> BatchStartWorker.new()
        |> Oban.insert()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :email_verification)

      assert Repo.get!(Oban.Job, job.id).args == %{"batch_uuid" => batch.uuid}
      assert Repo.aggregate(from(i in BatchItem, where: i.batch_uuid == ^batch.uuid), :count) == 1
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
      assert {:cancel, :not_a_member} =
               perform_job(VerifyEmailWorker, %{
                 "batch_uuid" => Ecto.UUID.generate(),
                 "item_uuid" => Ecto.UUID.generate()
               })

      assert {:cancel, :batch_not_found} =
               perform_job(VerifyEmailWorker, %{
                 "batch_uuid" => Ecto.UUID.generate(),
                 "email" => "john@fixture.org"
               })
    end

    test "an item that is not a member of the batch is ignored", %{batch: batch} do
      assert {:cancel, :not_a_member} =
               perform_job(VerifyEmailWorker, %{
                 "batch_uuid" => batch.uuid,
                 "item_uuid" => Ecto.UUID.generate()
               })

      assert {:cancel, :not_a_member} =
               perform_job(VerifyEmailWorker, %{
                 "batch_uuid" => batch.uuid,
                 "email" => "stranger@fixture.org"
               })

      assert {:cancel, :malformed_args} = perform_job(VerifyEmailWorker, %{"foo" => "bar"})
      assert reload(batch).processed == 0
    end

    test "a job of an earlier version, with the address in its args, still works", %{
      batch: batch
    } do
      args = %{"batch_uuid" => batch.uuid, "email" => "john@fixture.org"}

      assert :ok = perform_job(VerifyEmailWorker, args)

      assert reload(batch).processed == 1

      assert Repo.get_by!(BatchItem, batch_uuid: batch.uuid, email: "john@fixture.org").state ==
               "done"
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

  describe "Retry.decide/2" do
    alias PhoenixKit.Modules.Emails.Verification.Retry

    defp temp(reason), do: %Result{status: "temp", reason: reason}

    test "everything else is final" do
      assert :done = Retry.decide(%Result{status: "invalid", reason: "no_mx"}, 0)
      assert :done = Retry.decide(%Result{status: "not_sure", reason: "smtp_disabled"}, 0)
      assert :done = Retry.decide(temp("disposable"), 0)
    end

    test "a greylisted result is the SMTP queue's to retry, not the batch job's" do
      assert :done = Retry.decide(temp("greylisted"), 0)
    end
  end

  describe "a job that fails for good" do
    defmodule RaisingResolver do
      @behaviour PhoenixKit.Modules.Emails.Verification.Resolver

      @impl true
      def lookup_mx(_domain, _timeout), do: raise("resolver is down")

      @impl true
      def lookup_addresses(_domain, _timeout), do: raise("resolver is down")
    end

    setup do
      Application.put_env(:phoenix_kit_emails, :verification_resolver, RaisingResolver)
      batch = start(["john@fixture.org", "broken"])
      :ok = run_start_worker(batch)
      {:ok, batch: batch}
    end

    test "an early failure leaves the item pending and the error to Oban", %{batch: batch} do
      assert_raise RuntimeError, "resolver is down", fn ->
        perform_verify_attempt(batch, "john@fixture.org", 2)
      end

      assert reload(batch).processed == 0
      assert Enum.find(items(batch), &(&1.email == "john@fixture.org")).state == "pending"
    end

    test "the last attempt counts the address as temp, so the batch can still finish",
         %{batch: batch} do
      :ok = perform_verify(batch, "broken")

      assert_raise RuntimeError, "resolver is down", fn ->
        perform_verify_attempt(batch, "john@fixture.org", 3)
      end

      done = reload(batch)
      assert done.state == "done"
      assert done.processed == 2
      assert done.counts == %{"invalid" => 1, "temp" => 1}
      assert %DateTime{} = done.finished_at
      assert Enum.find(items(batch), &(&1.email == "john@fixture.org")).state == "done"
    end

    test "the address that was given up on has a temp row, so the summary agrees with the batch",
         %{batch: batch} do
      :ok = perform_verify(batch, "broken")

      assert_raise RuntimeError, fn -> perform_verify_attempt(batch, "john@fixture.org", 3) end

      emails = ["john@fixture.org", "broken"]
      assert %{temp: 1, invalid: 1, unchecked: 0} = Verification.summary(emails)
      assert reload(batch).counts == %{"invalid" => 1, "temp" => 1}

      assert %Result{status: "temp", reason: "job_failed", source: "cache"} =
               Verification.results_for(emails)["john@fixture.org"]

      assert %{status: "temp", reason: "job_failed"} =
               Verification.statuses_for(emails)["john@fixture.org"]
    end

    test "a verdict that already says temp keeps its reason", %{batch: batch} do
      FakeResolver.put("flaky-fixture.org", mx: {:error, :servfail})

      {:ok, %Result{reason: "dns_error"}} =
        Verification.verify("a@flaky-fixture.org", resolver: FakeResolver)

      :ok = Batches.give_up(batch.uuid, "a@flaky-fixture.org")

      assert %Result{status: "temp", reason: "dns_error", attempts: 1} =
               Verification.results_for(["a@flaky-fixture.org"])["a@flaky-fixture.org"]
    end

    test "an older verdict of another status is replaced, as the batch counted temp",
         %{batch: batch} do
      {:ok, %Result{status: "not_sure"}} =
        Verification.verify("john@fixture.org", resolver: FakeResolver)

      :ok = Batches.give_up(batch.uuid, "john@fixture.org")

      assert %Result{status: "temp", reason: "job_failed"} =
               Verification.results_for(["john@fixture.org"])["john@fixture.org"]
    end

    test "logs mask the local part of the address", %{batch: batch} do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert :ok = Batches.give_up("not-a-uuid", "john.smith@fixture.org")
        end)

      assert log =~ "j***@fixture.org"
      refute log =~ "john"
      refute log =~ "smith"
      assert batch.uuid
    end

    test "draining the queue through every retry still finishes the batch", %{batch: batch} do
      Oban.drain_queue(queue: :email_verification, with_scheduled: true, with_recursion: true)

      done = reload(batch)
      assert done.state == "done"
      assert done.counts == %{"invalid" => 1, "temp" => 1}
    end

    test "a failure on the last attempt of a cancelled batch changes nothing", %{batch: batch} do
      {:ok, _} = Verification.cancel_batch(batch.uuid)

      assert {:cancel, :batch_cancelled} = perform_verify_attempt(batch, "john@fixture.org", 3)
      assert reload(batch).processed == 0
    end

    test "the start worker cancels the batch when its last attempt fails" do
      batch = start(["a@fixture.org", "b\0@fixture.org"])
      args = %{"batch_uuid" => batch.uuid, "emails" => ["a@fixture.org", "b\0@fixture.org"]}

      assert_raise Postgrex.Error, fn -> perform_job(BatchStartWorker, args, attempt: 2) end
      assert reload(batch).state in ["queued", "running"]

      assert_raise Postgrex.Error, fn -> perform_job(BatchStartWorker, args, attempt: 3) end
      assert %Batch{state: "cancelled", finished_at: %DateTime{}} = reload(batch)
    end
  end

  describe "mask_addresses/1" do
    test "masks every address in a message the way the other batch logs do" do
      message =
        "ERROR 23505: Key (email)=(john.smith@fixture.org) conflicts with <ann@x.example>, b@y.example."

      masked = Batches.mask_addresses(message)

      assert masked =~ "(j***@fixture.org)"
      assert masked =~ "<a***@x.example>"
      assert masked =~ "b***@y.example."
      refute masked =~ "john"
      refute masked =~ "ann@"
    end

    test "leaves a message without an address alone" do
      assert Batches.mask_addresses("connection closed") == "connection closed"
    end

    test "a batch that could not be started is logged without a raw address, whatever the failure" do
      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          Batches.warn_start_failed("insert failed: Key (email)=(john.smith@fixture.org)")
          Batches.warn_start_failed(inspect({:error, %{args: ["ann.lee@fixture.org"]}}))
        end)

      assert log =~ "could not start a batch"
      assert log =~ "(j***@fixture.org)"
      assert log =~ "a***@fixture.org"
      refute log =~ "john.smith"
      refute log =~ "ann.lee"
    end

    test "the start worker logs a failed last attempt without a raw address" do
      batch = start(["john.smith@fixture.org", "b\0@fixture.org"])

      args = %{
        "batch_uuid" => batch.uuid,
        "emails" => ["john.smith@fixture.org", "b\0@fixture.org"]
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert_raise Postgrex.Error, fn -> perform_job(BatchStartWorker, args, attempt: 3) end
        end)

      assert log =~ "could not be laid out"
      refute log =~ "john.smith"
    end
  end

  describe "total" do
    test "follows the items when the database folds case differently from Elixir" do
      # citext lower-cases "İ" to "i"; String.downcase/1 does not.
      batch = start(["İ@fixture.org", "i@fixture.org"])
      assert batch.total == 1
      assert length(items(batch)) == 1

      :ok = run_start_worker(batch)

      assert reload(batch).total == 1
      assert length(verify_jobs(batch)) == 1

      [job] = verify_jobs(batch)
      :ok = perform_job(VerifyEmailWorker, job.args)
      assert reload(batch).state == "done"
    end
  end

  describe "start_batch/4 input" do
    test "a source_ref that is not text is refused, not raised on" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Verification.start_batch(["a@fixture.org"], "manual", {:a, 1})

      assert %{source_ref: [_]} = errors_on(changeset)
      assert Verification.list_batches("manual", {:a, 1}) == []
      assert Verification.latest_batch("manual", %{}) == nil
    end

    test "an atom or integer source_ref is its text" do
      assert {:ok, %Batch{source_ref: "list"}} =
               Verification.start_batch(["a@fixture.org"], "manual", :list)

      assert {:ok, %Batch{source_ref: "42"}} =
               Verification.start_batch(["a@fixture.org"], "manual", 42)

      assert [%Batch{source_ref: "42"}] = Verification.list_batches("manual", 42)
    end

    test "NUL bytes and invalid UTF-8 in title or source_ref are changeset errors" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Verification.start_batch(["a@fixture.org"], "manual", "r\0x", title: "t")

      assert %{source_ref: [_]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Verification.start_batch(["a@fixture.org"], "manual", "r", title: "t\0")

      assert %{title: [_]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{}} =
               Verification.start_batch(["a@fixture.org"], "manual", "r", title: <<255>>)

      assert Verification.list_batches("manual", "r\0x") == []
      assert Verification.latest_batch("manual", <<255>>) == nil
      assert Repo.aggregate(Batch, :count) == 0
    end

    test "a title that is not text is refused" do
      assert {:error, %Ecto.Changeset{}} =
               Verification.start_batch(["a@fixture.org"], "manual", nil, title: 5)
    end

    test "returns an error instead of raising when no Oban instance is running" do
      stop_supervised!(Oban)

      assert {:error, _reason} = Verification.start_batch(["a@fixture.org"], "manual", "ref")
      assert Repo.aggregate(Batch, :count) == 0
    end

    test "refuses more than the documented maximum of distinct addresses" do
      max = Verification.max_batch_size()
      emails = for n <- 1..(max + 1), do: "user#{n}@fixture.org"

      assert {:error, :too_many_emails} = Verification.start_batch(emails, "manual", nil)
      assert Repo.aggregate(Batch, :count) == 0

      # Duplicates do not count towards it.
      assert {:ok, %Batch{total: ^max}} =
               Verification.start_batch(
                 Enum.take(emails, max) ++ ["USER1@fixture.org"],
                 "manual",
                 nil
               )
    end
  end

  describe "progress messages" do
    alias PhoenixKit.Modules.Emails.Verification.Batches

    test "a message carries the row as it is when it is sent" do
      batch = start(["a@fixture.org", "b@fixture.org"])
      :ok = run_start_worker(batch)
      :ok = Verification.subscribe_batch(batch.uuid)

      {1, _} =
        Repo.update_all(from(b in Batch, where: b.uuid == ^batch.uuid),
          set: [processed: 1, counts: %{"not_sure" => 1}]
        )

      :ok = Batches.broadcast(batch.uuid)

      assert_receive {:email_verify_batch,
                      %{state: "running", processed: 1, total: 2, counts: %{"not_sure" => 1}}}
    end

    test "the last message of a batch run job by job is its final state" do
      batch = start(["a@fixture.org", "b@fixture.org", "c@fixture.org"])
      :ok = run_start_worker(batch)
      :ok = Verification.subscribe_batch(batch.uuid)

      for email <- ["a@fixture.org", "b@fixture.org", "c@fixture.org"],
          do: :ok = perform_verify(batch, email)

      assert_receive {:email_verify_batch, %{processed: 1, state: "running"}}
      assert_receive {:email_verify_batch, %{processed: 2, state: "running"}}
      assert_receive {:email_verify_batch, %{processed: 3, state: "done"}}
    end
  end

  describe "uniqueness" do
    test "the same batch and address is one incomplete job" do
      batch = start(["a@fixture.org", "b@fixture.org"])
      args = verify_args(batch.uuid, "a@fixture.org")

      {:ok, first} = Oban.insert(VerifyEmailWorker.new(args))
      {:ok, second} = Oban.insert(VerifyEmailWorker.new(args))
      assert second.conflict?
      assert second.id == first.id

      assert length(verify_jobs(batch)) == 1

      {:ok, _} = Oban.insert(VerifyEmailWorker.new(verify_args(batch.uuid, "b@fixture.org")))
      assert length(verify_jobs(batch)) == 2
    end

    test "queue and retry options" do
      changeset = VerifyEmailWorker.new(%{"batch_uuid" => "x", "item_uuid" => "y"})
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

    test "list_batches/2 and latest_batch/2 answer [] / nil for a source type that is not text" do
      start(["a@fixture.org"])

      for bad <- [nil, :manual, 42, %{}, ["manual"], <<0xFF>>, "man\0ual"] do
        assert Verification.list_batches(bad, "ref-1") == [], "list_batches(#{inspect(bad)})"
        assert Verification.latest_batch(bad, "ref-1") == nil, "latest_batch(#{inspect(bad)})"
      end

      assert Verification.list_batches("manual", <<0xFF>>) == []
      assert Verification.latest_batch("manual", {:not, :text}) == nil
      assert [_] = Verification.list_batches("manual", "ref-1")
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
