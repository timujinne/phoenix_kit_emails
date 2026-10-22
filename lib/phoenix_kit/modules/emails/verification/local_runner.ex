defmodule PhoenixKit.Modules.Emails.Verification.LocalRunner do
  @moduledoc """
  The built-in runner of the SMTP mode `local`: the site's own server takes the sessions
  from the same queue a remote runner does and opens the connections itself. There is
  no second path: it calls `SmtpQueue.claim/3`, runs each session with
  `Smtp.Direct` and reports through `SmtpQueue.report/4`, so the classifier, the retries,
  the domain throttling (one live session per domain, the interval, the domain pause) and
  the runner autopause apply to it exactly as to a remote runner.

  It is a runner with a row in `phoenix_kit_email_verify_runners` (`Runners.local_key/0`
  instead of an API key; `name` is the host, `helo_auto` the `EHLO` name in use) and is
  driven by `LocalRunnerWorker`, an Oban job that repeats itself while there is work and
  the mode is `local`.

  ## One cycle (`cycle/1`)

    1. Heartbeat, so the status line shows the host.
    2. The self-test of port 25 (`Smtp.Direct.check_port/3`, against
       `Runners.selftest_host/0`) when it has not run for ten minutes or since the mode
       was switched to `local`. A port found `"blocked"` starts no session until a
       later self-test finds it open.
    3. `SmtpQueue.claim/3` for the free slots (at most `sessions_limit/0` sessions are
       leased at a time, counted from the queue just before the claim; two cycles
       overlapping may briefly exceed it, which the one-live-session-per-domain rule
       keeps small), no claim without a `MAIL FROM` (`claim` hands out nothing then) and
       none while the runner is paused.
    4. The sessions run concurrently, each in its own task, then their results are
       reported together.

  The `EHLO` name is the setting `email_verify_smtp_helo` or the server's own name.
  Connections go to port 25 of the mail hosts the queue names - which is the point of
  this mode, and why it is off by default. Tests hand the cycle the port of a fake mail
  host on 127.0.0.1 (`:port`) and the test config allows nothing but the loopback
  interface.

  Application env: `:verification_local_sessions` - sessions at a time (default 3).
  """

  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.LocalRunnerWorker
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.Smtp.Direct
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @default_sessions 3
  @selftest_every_s 600
  @busy_delay_s 1
  @throttled_delay_s 5
  # A session ends within the 240 s of `Smtp.Direct` (its connect waits count inside that
  # limit); the rest is room for the report.
  @task_timeout_ms 360_000

  @type cycle_result :: %{sessions: non_neg_integer(), held_back?: boolean()}

  @doc """
  Runs one cycle. `:stopped` when the effective mode is not `"local"`; otherwise
  `%{sessions:, held_back?:}` - how many sessions ran, and whether something stops the
  runner from starting any (a closed port 25, a pause, no `MAIL FROM`).

  Options (tests): `:now`, `:port` and `:hard_ms` (for `Smtp.Direct`).
  """
  @spec cycle(keyword()) :: cycle_result() | :stopped
  def cycle(opts \\ []) do
    if Config.smtp_mode() == "local" do
      runner = Runners.heartbeat_local(info(), now(opts))
      runner = selftest(runner, opts)
      {sessions, held_back?} = run_sessions(runner, opts)
      %{sessions: sessions, held_back?: held_back?}
    else
      :stopped
    end
  end

  @doc """
  Starts the worker, because an address was queued: nothing happens unless the mode is
  `local`. Best effort - a failure to schedule never fails the caller.
  """
  @spec wake() :: :ok
  def wake do
    if Config.smtp_mode() == "local", do: LocalRunnerWorker.schedule(0)
    :ok
  end

  @doc """
  The mode has been switched to `local`: forget the old port 25 finding so that the
  next cycle checks it, and start the worker.
  """
  @spec activate() :: :ok
  def activate do
    Runners.reset_local_selftest()
    LocalRunnerWorker.schedule(0)
  end

  @doc """
  The wait, in seconds, before the next cycle: `:stop` when nothing is queued or leased any
  more (the next queued address starts the worker again), a second after a cycle that ran
  sessions, otherwise until the earliest address is due, within `idle_poll_s` (a few seconds
  when something is due but held back by a domain's interval).
  """
  @spec next_delay(cycle_result(), DateTime.t()) :: pos_integer() | :stop
  def next_delay(%{sessions: sessions, held_back?: held_back?}, now \\ UtilsDate.utc_now()) do
    counts = SmtpQueue.counts()
    idle = Config.idle_poll_s()

    cond do
      counts.queued + counts.leased == 0 -> :stop
      sessions > 0 -> @busy_delay_s
      held_back? -> idle
      true -> idle |> min(due_wait(SmtpQueue.next_due_in(now))) |> max(1)
    end
  end

  defp due_wait(nil), do: @throttled_delay_s * 6
  defp due_wait(0), do: @throttled_delay_s
  defp due_wait(seconds), do: seconds

  @doc "How many sessions the built-in runner runs at a time."
  @spec sessions_limit() :: pos_integer()
  def sessions_limit do
    case Application.get_env(:phoenix_kit_emails, :verification_local_sessions, @default_sessions) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @default_sessions
    end
  end

  @doc """
  The name this server gives in `EHLO` when the setting is empty: its fully qualified host
  name when the system knows one, else the plain host name, else `localhost`. Cached.
  """
  @spec server_name() :: String.t()
  def server_name do
    case :persistent_term.get({__MODULE__, :server_name}, nil) do
      nil ->
        name = find_server_name()
        :persistent_term.put({__MODULE__, :server_name}, name)
        name

      name ->
        name
    end
  end

  @doc "The `EHLO` name in use: `email_verify_smtp_helo`, else `server_name/0`."
  @spec helo() :: String.t()
  def helo, do: Config.smtp_helo() || server_name()

  defp find_server_name do
    with {:ok, short} <- :inet.gethostname(),
         short = List.to_string(short),
         {:ok, {:hostent, full, _, _, _, _}} <- :inet.gethostbyname(String.to_charlist(short)),
         full = List.to_string(full),
         true <- Config.helo_name?(full) do
      full
    else
      _ -> short_name()
    end
  end

  defp short_name do
    with {:ok, short} <- :inet.gethostname(),
         short = List.to_string(short),
         true <- Config.helo_name?(short) do
      short
    else
      _ -> "localhost"
    end
  end

  ## --- The cycle ---

  defp info do
    {family, name} = :os.type()

    %{
      name: server_name(),
      version: "local",
      os:
        "#{name} (#{family}) / Elixir #{System.version()} / OTP #{:erlang.system_info(:otp_release)}",
      helo_auto: helo()
    }
  end

  defp selftest(runner, opts) do
    if selftest_due?(runner, now(opts)) do
      state = port_state(opts)
      Runners.heartbeat_local(%{port25: state}, now(opts))
    else
      runner
    end
  end

  defp selftest_due?(%Runner{port25_checked_at: nil}, _now), do: true

  defp selftest_due?(%Runner{port25_checked_at: checked}, now),
    do: DateTime.diff(now, checked, :second) >= @selftest_every_s

  # No host to test against says nothing about the port: sessions are allowed, and a
  # port that really is closed shows in the sessions (and ends in the runner pause).
  defp port_state(opts) do
    case Runners.selftest_host() do
      nil ->
        "unknown"

      host ->
        host |> Direct.check_port(timeouts(), Keyword.take(opts, [:port])) |> Map.fetch!(:state)
    end
  end

  defp timeouts do
    %{
      connect_timeout_s: Config.smtp_connect_timeout_s(),
      read_timeout_s: Config.smtp_read_timeout_s()
    }
  end

  defp run_sessions(%Runner{port25: "blocked"}, _opts), do: {0, true}

  defp run_sessions(runner, opts) do
    now = now(opts)
    free = max(sessions_limit() - SmtpQueue.sessions_held(runner, now), 0)

    case SmtpQueue.claim(runner, free, now) do
      {:ok, []} -> {0, no_sender?()}
      {:ok, sessions} -> {execute(sessions, runner, opts), false}
      {:paused, _reason} -> {0, true}
    end
  end

  defp no_sender?, do: match?({nil, _source}, Config.smtp_mail_from())

  defp execute(sessions, runner, opts) do
    {mail_from, _source} = Config.smtp_mail_from()
    settings = Map.merge(timeouts(), %{mail_from: mail_from, helo: helo()})
    direct_opts = Keyword.take(opts, [:port, :hard_ms])

    reports =
      sessions
      |> Task.async_stream(&safe_run(&1, settings, direct_opts),
        max_concurrency: length(sessions),
        timeout: @task_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, report}} -> [report]
        _other -> []
      end)

    {:ok, _summary} = SmtpQueue.report(runner, reports, now(opts))
    length(sessions)
  end

  # A session that crashes (a bug) must not take the cycle down with it: its lease runs
  # out and the queue puts the addresses back, as for a runner that went away.
  defp safe_run(session, settings, direct_opts) do
    Direct.run(session, settings, direct_opts)
  rescue
    error ->
      Logger.error(
        "[Emails.Verification] a session of the built-in SMTP runner crashed: " <>
          Batches.mask_addresses(Exception.message(error))
      )

      :crashed
  end

  defp now(opts), do: Keyword.get(opts, :now) || UtilsDate.utc_now()
end
