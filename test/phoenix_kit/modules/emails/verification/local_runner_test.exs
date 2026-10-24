defmodule PhoenixKit.Modules.Emails.Verification.LocalRunnerTest do
  @moduledoc """
  The built-in runner (SMTP mode `local`): one cycle claims sessions from the queue, runs
  them with `Smtp.Direct` against a fake mail host on 127.0.0.1 (started here, ephemeral
  port; the test config allows nothing else) and reports them through the same
  `SmtpQueue.report` path a remote runner uses. Covers the results, the batch it finishes,
  the domain throttling, the bounded concurrency, the autopause, the port 25 self-test,
  the switch of the mode and the worker chain. Nothing connects to a real host.
  """

  # Not async: Oban and the PubSub manager are named singletons, and the session limit is
  # an application setting.
  use PhoenixKitEmails.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitEmails.Test.Repo

  import Ecto.Query
  import PhoenixKitEmails.Test.SmtpHelpers

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.BatchStartWorker
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.LocalRunner
  alias PhoenixKit.Modules.Emails.Verification.LocalRunnerWorker
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKit.Modules.Emails.Verification.SmtpSettings
  alias PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.FakeSmtpServer
  alias PhoenixKitEmails.Test.Repo

  @now ~U[2026-10-20 10:00:00Z]

  # A mail host that knows `nobody@` and the catch-all probe addresses (x...@) as unknown
  # and accepts the rest.
  @picky %{
    "banner" => ["220 mx.example.test ESMTP ready"],
    "rules" => [
      %{"match" => "^RCPT TO:<(nobody|x[a-z0-9]+)@", "reply" => ["550 5.1.1 User unknown"]},
      %{"match" => "^EHLO ", "reply" => ["250 mx.example.test"]},
      %{"match" => "^MAIL FROM:", "reply" => ["250 2.1.0 Ok"]},
      %{"match" => "^RCPT TO:", "reply" => ["250 2.1.5 Ok"]},
      %{"match" => "^QUIT", "reply" => ["221 2.0.0 Bye"], "then" => "close"}
    ]
  }

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: false, plugins: false})
    start_supervised!({Phoenix.PubSub, name: :phoenix_kit_internal_pubsub})

    put("email_verify_smtp_mode", "local")
    put("from_email", "mail@acme-mail.test")
    put("email_verify_smtp_selftest_host", "127.0.0.1")
    put("email_verify_smtp_helo", "runner.example.test")
    put("email_verify_domain_interval_s", "10")

    on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_local_sessions) end)
    :ok
  end

  # Addresses of `domain` queued the way a batch job queues them; the mail host of the
  # domain is the loopback interface.
  defp queue_local(domain, locals) do
    FakeResolver.put(domain, mx: {:ok, [%{host: "127.0.0.1", pref: 10}]})

    for local <- locals do
      assert {:ok, %Result{reason: "smtp_pending"}} =
               Verification.verify(local <> "@" <> domain, smtp: :enqueue)
    end
  end

  # The port 25 finding is fresh, so that a cycle goes straight to the sessions.
  defp selftested(port25 \\ "open", at \\ @now) do
    Runners.heartbeat_local(%{port25: port25}, at)
  end

  defp cycle(server, opts \\ []),
    do: LocalRunner.cycle(Keyword.merge([port: server.port, now: @now], opts))

  defp result(email), do: Repo.get_by!(Result, email: email)
  defp item(email), do: Repo.get_by!(Item, email: email)
  defp local_row, do: Repo.get_by!(Runner, api_key_uuid: Runners.local_key())

  describe "a cycle" do
    test "claims a session, runs the dialogue, and the classifier settles the results" do
      domain = unique_domain()
      queue_local(domain, ~w(info nobody))
      selftested()
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 1, held_back?: false} = cycle(server)

      assert %{status: "valid", reason: "smtp_ok", level: "smtp"} = result("info@" <> domain)
      assert %{status: "invalid", reason: "mailbox_unknown"} = result("nobody@" <> domain)
      assert %{state: "done"} = item("info@" <> domain)
      assert %{state: "done"} = item("nobody@" <> domain)

      commands = FakeSmtpServer.commands(server)

      assert ["EHLO runner.example.test", "MAIL FROM:<mail@acme-mail.test>", probe | rest] =
               commands

      assert probe =~ ~r/\ARCPT TO:<x[a-z0-9]+@#{Regex.escape(domain)}>\z/
      assert rest == ["RCPT TO:<info@#{domain}>", "RCPT TO:<nobody@#{domain}>", "QUIT"]
      refute Enum.any?(commands, &String.starts_with?(&1, "DATA"))

      # The domain facts and the runner's books are the remote runner's.
      assert %{catch_all: false, last_smtp_at: @now} = DomainCache.get(domain)

      assert %{jobs_done: 2, name: name, version: "local", helo_auto: "runner.example.test"} =
               local_row()

      assert name == LocalRunner.server_name()
    end

    test "the leases are the runner's and a repeated cycle finds nothing to do" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 1} = cycle(server)
      assert %{sessions: 0} = cycle(server)
      assert SmtpQueue.counts() == %{queued: 0, leased: 0}
      assert FakeSmtpServer.connections(server) == 1
    end

    test "an empty HELO setting falls back to the name of this server" do
      put("email_verify_smtp_helo", "")
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      server = FakeSmtpServer.start(@picky)

      cycle(server)

      assert hd(FakeSmtpServer.commands(server)) == "EHLO " <> LocalRunner.server_name()
      assert LocalRunner.helo() == LocalRunner.server_name()
      assert LocalRunner.server_name() =~ ~r/\A[A-Za-z0-9.-]+\z/
    end

    test "a greylisted address goes back to the queue with the retry the queue gives" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()

      server =
        FakeSmtpServer.start(%{
          @picky
          | "rules" => [
              %{"match" => "^RCPT TO:<info@", "reply" => ["451 4.7.1 try later"]}
              | @picky["rules"]
            ]
        })

      assert %{sessions: 1} = cycle(server)

      assert %{state: "queued", grey_attempts: 1, not_before: not_before} =
               item("info@" <> domain)

      assert DateTime.diff(not_before, @now) == 20 * 60
    end

    test "finishes the batch that waited for it" do
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "127.0.0.1", pref: 10}]})
      emails = ["info@" <> domain, "nobody@" <> domain]
      {:ok, batch} = Verification.start_batch(emails, "manual", "local-1")

      job =
        Enum.find(all_enqueued(worker: BatchStartWorker), &(&1.args["batch_uuid"] == batch.uuid))

      :ok = perform_job(BatchStartWorker, job.args)

      for email <- emails,
          do: :ok = perform_job(VerifyEmailWorker, verify_args(batch.uuid, email))

      assert %{state: "running", awaiting_smtp: 2, processed: 0} = Repo.get!(Batch, batch.uuid)

      selftested()
      cycle(FakeSmtpServer.start(@picky))

      assert %{state: "done", awaiting_smtp: 0, processed: 2, counts: counts} =
               Repo.get!(Batch, batch.uuid)

      assert counts == %{"valid" => 1, "invalid" => 1}
    end
  end

  describe "the domain throttling of the queue applies" do
    test "one session per domain at a time, and the interval between sessions" do
      domain = unique_domain()
      queue_local(domain, Enum.map(1..15, &"a#{&1}"))
      selftested()
      server = FakeSmtpServer.start(@picky)

      # Ten addresses per session; the other five wait for the interval to pass.
      assert %{sessions: 1} = cycle(server)
      assert SmtpQueue.counts() == %{queued: 5, leased: 0}

      assert %{sessions: 0} = cycle(server, now: DateTime.add(@now, 5))
      assert SmtpQueue.counts().queued == 5

      assert %{sessions: 1} = cycle(server, now: DateTime.add(@now, 11))
      assert SmtpQueue.counts() == %{queued: 0, leased: 0}
      assert FakeSmtpServer.connections(server) == 2
    end

    test "a paused domain is left alone" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      blocked = %{catch_all: nil, blocked: true, grey_message: nil}

      for _block <- 1..2,
          do: Repo.transaction(fn -> DomainCache.record_session(domain, blocked, @now) end)

      assert DomainCache.get(domain).paused_until

      server = FakeSmtpServer.start(@picky)
      assert %{sessions: 0} = cycle(server, now: DateTime.add(@now, 30))
      assert FakeSmtpServer.connections(server) == 0
    end
  end

  describe "a session that crashes" do
    test "does not stop the cycle; its lease is left to run out" do
      # A mail host outside the loopback interface: the test config makes the session
      # raise before it connects to anything.
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.example.com", pref: 10}]})
      {:ok, _} = Verification.verify("info@" <> domain, smtp: :enqueue)
      selftested()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{sessions: 1} = cycle(FakeSmtpServer.start(@picky))
        end)

      assert log =~ "a session of the built-in SMTP runner crashed"
      refute log =~ "info@"
      assert %{state: "leased"} = item("info@" <> domain)

      # The lease runs out, the address goes back to the queue.
      later = DateTime.add(@now, 400)
      assert SmtpQueue.expire_leases(later) == 1
      assert %{state: "queued", lease_expiries: 1} = item("info@" <> domain)
    end
  end

  describe "bounded concurrency" do
    test "no more sessions at a time than the limit, and they run side by side" do
      Application.put_env(:phoenix_kit_emails, :verification_local_sessions, 2)
      for n <- 1..5, do: queue_local(unique_domain("c#{n}-"), ~w(info))
      selftested()

      slow = %{
        @picky
        | "rules" => [
            %{"match" => "^MAIL FROM:", "delay" => 0.4, "reply" => ["250 Ok"]} | @picky["rules"]
          ]
      }

      server = FakeSmtpServer.start(slow)

      assert %{sessions: 2} = cycle(server)
      assert FakeSmtpServer.peak(server) == 2
      assert SmtpQueue.counts().queued == 3
    end

    test "sessions another cycle still holds count against the limit" do
      Application.put_env(:phoenix_kit_emails, :verification_local_sessions, 2)
      for n <- 1..3, do: queue_local(unique_domain("h#{n}-"), ~w(info))
      runner = selftested()

      # A cycle that is still running holds one session.
      assert {:ok, [_held]} = SmtpQueue.claim(runner, 1, @now)
      assert SmtpQueue.sessions_held(runner, @now) == 1

      server = FakeSmtpServer.start(@picky)
      assert %{sessions: 1} = cycle(server)
    end
  end

  describe "no sender, no session" do
    test "without a usable MAIL FROM nothing is claimed and nothing is connected" do
      put("from_email", "noreply@localhost")
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 0, held_back?: true} = cycle(server)
      assert FakeSmtpServer.connections(server) == 0
      assert %{state: "queued"} = item("info@" <> domain)
    end

    test "a MAIL FROM override is enough" do
      put("from_email", "noreply@localhost")
      put("email_verify_smtp_mail_from", "verify@acme-mail.test")
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 1} = cycle(server)
      assert "MAIL FROM:<verify@acme-mail.test>" in FakeSmtpServer.commands(server)
    end
  end

  describe "the mode" do
    test "off, runner: the cycle does nothing" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      server = FakeSmtpServer.start(@picky)

      for mode <- ~w(off runner) do
        put("email_verify_smtp_mode", mode)
        assert LocalRunner.cycle(port: server.port, now: @now) == :stopped
      end

      assert FakeSmtpServer.connections(server) == 0
    end

    test "the worker ends its chain when the mode is no longer local" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      put("email_verify_smtp_mode", "runner")
      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(LocalRunnerWorker, %{})
      refute_enqueued(worker: LocalRunnerWorker)
    end

    test "switching to off settles the queue instead of leaving it to the built-in runner" do
      domain = unique_domain()
      queue_local(domain, ~w(info))

      assert {:ok, %{mode: "off", drained: 1}} = SmtpSettings.save_mode("off")
      assert %{status: "not_sure", reason: "smtp_disabled"} = result("info@" <> domain)
    end

    test "switching to local forgets the port 25 finding and starts the worker" do
      selftested("blocked")
      Repo.delete_all(Oban.Job)

      assert {:ok, %{mode: "local", drained: 0}} = SmtpSettings.save_mode("local")

      assert %{port25: "unknown", port25_checked_at: nil} = local_row()
      assert_enqueued(worker: LocalRunnerWorker)
    end
  end

  describe "the port 25 self-test" do
    test "an open port is recorded and the sessions follow" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 1} = cycle(server)

      assert %{port25: "open", port25_checked_at: @now} = local_row()
      # The self-test said QUIT to the banner; then the session's own dialogue.
      assert ["QUIT", "EHLO " <> _ | _] = FakeSmtpServer.commands(server)
    end

    test "a closed port starts no session, and is looked at again after ten minutes" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      closed = FakeSmtpServer.closed_port()

      assert %{sessions: 0, held_back?: true} = LocalRunner.cycle(port: closed, now: @now)
      assert %{port25: "blocked"} = local_row()
      assert %{state: "queued"} = item("info@" <> domain)

      server = FakeSmtpServer.start(@picky)
      later = DateTime.add(@now, 60)
      assert %{sessions: 0, held_back?: true} = cycle(server, now: later)
      assert FakeSmtpServer.connections(server) == 0

      much_later = DateTime.add(@now, 601)
      assert %{sessions: 1} = cycle(server, now: much_later)
      assert %{port25: "open"} = local_row()
    end

    test "a host that connects but does not greet with 220 leaves the finding unknown" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      busy = FakeSmtpServer.start(%{"banner" => ["421 busy"], "banner_then" => "close"})

      assert %{sessions: 1} = LocalRunner.cycle(port: busy.port, now: @now)
      assert %{port25: "unknown"} = local_row()
    end

    test "no host to test against is no finding" do
      put("email_verify_smtp_selftest_host", "")
      FakeResolver.put("acme-mail.test", mx: {:error, :nxdomain})
      queue_local(unique_domain(), ~w(info))
      server = FakeSmtpServer.start(@picky)

      assert %{sessions: 1} = cycle(server)
      assert %{port25: "unknown"} = local_row()
    end
  end

  describe "the autopause" do
    test "sessions that fail on three domains in a row pause the built-in runner" do
      Application.put_env(:phoenix_kit_emails, :verification_local_sessions, 3)
      for n <- 1..6, do: queue_local(unique_domain("p#{n}-"), ~w(info))
      selftested()
      closed = FakeSmtpServer.closed_port()

      assert %{sessions: 3} = LocalRunner.cycle(port: closed, now: @now)
      assert %{sessions: 3} = LocalRunner.cycle(port: closed, now: DateTime.add(@now, 1))

      assert %{paused_until: until, pause_reason: reason} = local_row()
      assert until
      assert reason =~ "failed"

      # Paused: the work waits, and nothing is connected.
      server = FakeSmtpServer.start(@picky)
      assert %{sessions: 0, held_back?: true} = cycle(server, now: DateTime.add(@now, 120))
      assert FakeSmtpServer.connections(server) == 0
      assert %{paused: %{reason: ^reason}} = Runners.status(DateTime.add(@now, 120))

      # "Resume" lifts it.
      assert {:ok, 1} = Verification.clear_runner_pause()
      assert %{sessions: sessions} = cycle(server, now: DateTime.add(@now, 130))
      assert sessions > 0
    end
  end

  describe "the status" do
    test "the runner of the stored mode is the one the status shows" do
      queue_local(unique_domain(), ~w(info))
      selftested()
      cycle(FakeSmtpServer.start(@picky))
      other = runner()

      assert %{
               mode: "local",
               state: :online,
               runner: %{
                 name: name,
                 version: "local",
                 port25: "open",
                 helo_auto: "runner.example.test"
               },
               owner: nil
             } = Runners.status(@now)

      assert name == LocalRunner.server_name()

      put("email_verify_smtp_mode", "runner")
      assert %{mode: "runner", runner: %{uuid: uuid}} = Runners.status(@now)
      assert uuid == other.uuid
    end

    test "not started yet; idle with an empty queue is fine; silence with work waiting is not" do
      assert %{state: :never_connected, runner: nil} = Runners.status(@now)

      selftested()
      assert %{state: :online} = Runners.status(DateTime.add(@now, 3600))

      queue_local(unique_domain(), ~w(info))
      assert %{state: :online} = Runners.status(DateTime.add(@now, 60))
      assert %{state: :offline} = Runners.status(DateTime.add(@now, 3600))
    end
  end

  describe "the worker" do
    test "an address queued in local mode starts it, once" do
      Repo.delete_all(Oban.Job)
      queue_local(unique_domain(), ~w(a b c))

      assert [_one] = all_enqueued(worker: LocalRunnerWorker)
    end

    test "an address queued in another mode does not" do
      for mode <- ~w(off runner) do
        put("email_verify_smtp_mode", mode)
        Repo.delete_all(Oban.Job)
        domain = unique_domain()
        FakeResolver.put(domain, mx: {:ok, [%{host: "127.0.0.1", pref: 10}]})

        assert {:ok, %Result{}} = Verification.verify("a@" <> domain, smtp: :enqueue)
        refute_enqueued(worker: LocalRunnerWorker)
      end
    end

    test "a run does a cycle and puts its successor on the queue while work waits" do
      # One address per session: the second waits for the interval of its domain.
      put("email_verify_rcpt_per_session", "1")
      domain = unique_domain()
      queue_local(domain, ~w(info second))
      selftested()
      Repo.delete_all(Oban.Job)
      server = FakeSmtpServer.start(@picky)
      Application.put_env(:phoenix_kit_emails, :verification_smtp_port, server.port)
      on_exit(fn -> Application.put_env(:phoenix_kit_emails, :verification_smtp_port, 1) end)

      assert :ok = perform_job(LocalRunnerWorker, %{})

      assert %{state: "done"} = item("info@" <> domain)
      assert %{state: "queued"} = item("second@" <> domain)
      assert [%Oban.Job{scheduled_at: at}] = all_enqueued(worker: LocalRunnerWorker)
      assert DateTime.compare(at, DateTime.utc_now()) == :gt
    end

    test "with nothing left to do the chain ends" do
      domain = unique_domain()
      queue_local(domain, ~w(info))
      selftested()
      Repo.delete_all(Oban.Job)
      server = FakeSmtpServer.start(@picky)
      Application.put_env(:phoenix_kit_emails, :verification_smtp_port, server.port)
      on_exit(fn -> Application.put_env(:phoenix_kit_emails, :verification_smtp_port, 1) end)

      assert :ok = perform_job(LocalRunnerWorker, %{})

      assert %{state: "done"} = item("info@" <> domain)
      refute_enqueued(worker: LocalRunnerWorker)
    end

    test "only one job waits at a time" do
      Repo.delete_all(Oban.Job)
      LocalRunnerWorker.schedule(0)
      LocalRunnerWorker.schedule(30)
      LocalRunnerWorker.schedule(0)

      assert [_one] = all_enqueued(worker: LocalRunnerWorker)
    end

    test "the wait before the next cycle follows the queue" do
      assert LocalRunner.next_delay(%{sessions: 0, held_back?: false}, @now) == :stop

      domain = unique_domain()
      queue_local(domain, ~w(info))
      assert LocalRunner.next_delay(%{sessions: 2, held_back?: false}, @now) == 1
      assert LocalRunner.next_delay(%{sessions: 0, held_back?: true}, @now) == 30
      assert LocalRunner.next_delay(%{sessions: 0, held_back?: false}, @now) == 5

      from(i in Item, where: i.domain == ^domain)
      |> Repo.update_all(set: [not_before: DateTime.add(@now, 12)])

      assert LocalRunner.next_delay(%{sessions: 0, held_back?: false}, @now) == 12

      from(i in Item, where: i.domain == ^domain)
      |> Repo.update_all(set: [not_before: DateTime.add(@now, 1200)])

      assert LocalRunner.next_delay(%{sessions: 0, held_back?: false}, @now) == 30
    end
  end
end
