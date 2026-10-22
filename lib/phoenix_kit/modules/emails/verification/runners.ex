defmodule PhoenixKit.Modules.Emails.Verification.Runners do
  @moduledoc """
  The runners that connect to this site: who they are, whether they are alive, and
  the autopause that protects the IP of the machine they run on.

  A runner is identified by the API key it authenticates with (one row per key). The
  built-in runner of the mode `local` has no key: its one row carries the fixed
  `local_key/0` instead (`heartbeat_local/2`). Every `claim` is a heartbeat
  (`heartbeat/3`); every settled session feeds the
  autopause (`record_session/6`): five failed sessions in a row (a refused
  connection, or a block) on at least three different domains pause the runner for
  an hour, which means a closed port 25 or an IP on a blocklist. While paused, `claim`
  hands out nothing; `clear_pause/0` lifts it.

  `status/0` is what the settings UI shows. Changes are announced on the PubSub topic
  `"email_verify:runner"` as `{:email_verify_runner, %{event:, runner_uuid:}}` - a
  heartbeat at most every 5 seconds, a pause or its end at once - and the UI
  re-reads `status/0` on each.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.RunnerKeys
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @scope "emails.smtp_runner:run"
  @topic "email_verify:runner"
  @broadcast_gap_s 5
  @online_factor 3
  @runner_protocol_version "1.0.0"
  # The "key" of the built-in runner (mode `local`): no API key stands behind it.
  @local_key "00000000-0000-0000-0000-000000000001"
  # The built-in runner counts as stalled only after this long without a cycle while
  # work waits: one cycle can take minutes (a session has a few minutes of its own).
  @local_stall_s 600

  @type info :: %{
          optional(:name) => String.t() | nil,
          optional(:version) => String.t() | nil,
          optional(:os) => String.t() | nil,
          optional(:helo_auto) => String.t() | nil,
          optional(:port25) => String.t() | nil
        }

  @doc "The API scope of the runner's key (`emails.smtp_runner:run`)."
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  The version of the protocol between this server and the runner script
  (`priv/smtp_runner/pk-smtp-runner.ps1`): handed out as `min_version` in every claim
  answer, and a runner older than it stops with "update the runner". Bumped only when
  the script or the protocol changes in a way an old script cannot follow - never with
  the package version. The script carries the same number and a test compares them.
  """
  @spec runner_protocol_version() :: String.t()
  def runner_protocol_version, do: @runner_protocol_version

  ## --- PubSub ---

  @doc "The PubSub topic of runner changes: `\"email_verify:runner\"`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to `topic/0`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSubManager.subscribe(@topic)

  @doc false
  # Best effort: a broadcast never fails the caller.
  @spec broadcast(map()) :: :ok
  def broadcast(event) do
    PubSubManager.broadcast(@topic, {:email_verify_runner, event})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  ## --- Heartbeat ---

  @doc "The row again, as it is now."
  @spec reload(Runner.t()) :: Runner.t()
  def reload(%Runner{uuid: uuid}), do: repo().get!(Runner, uuid)

  @doc """
  Records that the runner behind `actor` (`%{key_uuid:, ip:}`, a
  `PhoenixKit.API.Actor`) is alive and says `info`; creates the row on first contact.
  Fields the runner did not send keep their value; only `helo_auto: nil` sent on
  purpose clears the stored EHLO name. Announces the contact on the
  topic (at most every 5 seconds). Returns the row.
  """
  @spec heartbeat(map(), info(), DateTime.t()) :: Runner.t()
  def heartbeat(%{key_uuid: key_uuid} = actor, info \\ %{}, now \\ UtilsDate.utc_now())
      when is_binary(key_uuid) do
    record_contact(key_uuid, Map.get(actor, :ip), info, now)
  end

  @doc """
  The heartbeat of the built-in runner (mode `local`): the same as `heartbeat/3` for the
  one row that has `local_key/0` instead of an API key. `info` is what the server says
  about itself (`:name` the host, `:os`, `:helo_auto` the `EHLO` name in use, `:port25`
  from its self-test).
  """
  @spec heartbeat_local(info(), DateTime.t()) :: Runner.t()
  def heartbeat_local(info \\ %{}, now \\ UtilsDate.utc_now()),
    do: record_contact(@local_key, nil, info, now)

  @doc "The `api_key_uuid` of the built-in runner's row."
  @spec local_key() :: String.t()
  def local_key, do: @local_key

  @doc "Whether `runner` is the built-in runner of the mode `local`."
  @spec local?(Runner.t() | nil) :: boolean()
  def local?(%Runner{api_key_uuid: @local_key}), do: true
  def local?(_runner), do: false

  @doc """
  Forgets what the built-in runner's port 25 self-test found, so the next cycle runs it
  again (a switch to the mode `local` does this).
  """
  @spec reset_local_selftest() :: :ok
  def reset_local_selftest do
    from(r in Runner, where: r.api_key_uuid == ^@local_key)
    |> repo().update_all(set: [port25: "unknown", port25_checked_at: nil])

    :ok
  end

  defp record_contact(key_uuid, ip, info, now) do
    now = DateTime.truncate(now, :second)
    previous = repo().get_by(Runner, api_key_uuid: key_uuid)
    port25 = valid_port25(Map.get(info, :port25))
    announce? = announce?(previous, port25, now)

    fields =
      [
        name: clip(Map.get(info, :name), 255),
        version: clip(Map.get(info, :version), 32),
        os: clip(Map.get(info, :os), 255),
        helo_auto: clip(Map.get(info, :helo_auto), 255),
        public_ip: clip(ip, 45),
        port25: port25,
        port25_checked_at: if(port25, do: now),
        last_seen_at: now,
        updated_at: if(announce?, do: now)
      ]
      |> Enum.reject(fn {field, value} -> is_nil(value) and not clears?(field, info) end)

    {:ok, runner} =
      repo().insert(struct(Runner, [api_key_uuid: key_uuid] ++ fields),
        on_conflict: [set: fields],
        conflict_target: :api_key_uuid,
        returning: true
      )

    if announce?, do: broadcast(%{event: :heartbeat, runner_uuid: runner.uuid})
    runner
  end

  # `updated_at` doubles as the time of the last announcement: it moves only when one
  # is made. The first contact and a changed port-25 finding are announced at once, a
  # plain heartbeat when the last announcement is five seconds old.
  # An explicit `helo_auto: nil` in the runner's info clears the stored EHLO name; for
  # every other field nil means "not told".
  defp clears?(:helo_auto, info), do: Map.has_key?(info, :helo_auto)
  defp clears?(_field, _info), do: false

  defp announce?(nil, _port25, _now), do: true

  defp announce?(previous, port25, now) do
    (not is_nil(port25) and port25 != previous.port25) or
      DateTime.diff(now, previous.updated_at, :second) >= @broadcast_gap_s
  end

  defp valid_port25(value) when is_binary(value) do
    if value in Runner.port25_values(), do: value
  end

  defp valid_port25(_value), do: nil

  defp clip(value, limit) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> String.slice(text, 0, limit)
    end
  end

  defp clip(_value, _limit), do: nil

  ## --- Autopause ---

  @doc """
  Counts one settled session against `claimant` and returns the events to announce
  (after the surrounding transaction has committed).

  A session that failed (`classification.failed`: the connection was refused, or the
  host blocked it) adds to the streak and remembers its domain; a clean answered
  session ends the streak; a timeout or a reset changes nothing. When the streak
  reaches `Config.runner_fail_sessions/0` on at least `Config.runner_fail_domains/0`
  distinct domains the runner is paused for `Config.runner_pause_s/0`.

  The built-in runner (mode `local`) has a row of its own and the same autopause.
  """
  @spec record_session(term(), String.t(), map(), String.t(), non_neg_integer(), DateTime.t()) ::
          [map()]
  def record_session(%Runner{uuid: uuid}, domain, classification, outcome, settled, now) do
    case repo().one(from(r in Runner, where: r.uuid == ^uuid, lock: "FOR UPDATE")) do
      nil ->
        Logger.warning(
          "[Emails.Verification] a session was settled for the runner #{uuid} whose row is gone"
        )

        []

      runner ->
        settle(runner, domain, classification, outcome, settled, now)
    end
  end

  def record_session(_claimant, _domain, _classification, _outcome, _settled, _now), do: []

  defp settle(runner, domain, classification, outcome, settled, now) do
    {streak, domains, last_error} = streak(runner, domain, classification, outcome)

    pause? =
      streak >= Config.runner_fail_sessions() and length(domains) >= Config.runner_fail_domains()

    changes =
      [
        jobs_done: runner.jobs_done + settled,
        fail_streak: if(pause?, do: 0, else: streak),
        fail_domains: if(pause?, do: [], else: domains),
        last_error: last_error
      ] ++ pause_changes(pause?, streak, domains, now)

    from(r in Runner, where: r.uuid == ^runner.uuid) |> repo().update_all(set: changes)

    if pause?, do: [%{event: :paused, runner_uuid: runner.uuid}], else: []
  end

  defp streak(runner, domain, %{failed: true}, outcome) do
    cause = if outcome == "connect_failed", do: "connect_failed", else: "smtp_blocked"

    {runner.fail_streak + 1, Enum.uniq(runner.fail_domains ++ [domain]), "#{cause} at #{domain}"}
  end

  defp streak(_runner, _domain, _classification, "answered"), do: {0, [], nil}

  defp streak(runner, _domain, _classification, _outcome),
    do: {runner.fail_streak, runner.fail_domains, runner.last_error}

  defp pause_changes(false, _streak, _domains, _now), do: []

  defp pause_changes(true, streak, domains, now) do
    [
      paused_until: DateTime.add(now, Config.runner_pause_s(), :second),
      pause_reason:
        "#{streak} sessions in a row failed on #{length(domains)} domains " <>
          "(port 25 closed, or this IP is blocked)"
    ]
  end

  @doc """
  Lifts the autopause of every runner and forgets the streak. `{:ok, n}` runners were
  paused.
  """
  @spec clear_pause() :: {:ok, non_neg_integer()}
  def clear_pause do
    {count, _} =
      from(r in Runner, where: not is_nil(r.paused_until) or r.fail_streak > 0)
      |> repo().update_all(
        set: [
          paused_until: nil,
          pause_reason: nil,
          fail_streak: 0,
          fail_domains: []
        ]
      )

    if count > 0, do: broadcast(%{event: :resumed, runner_uuid: nil})
    {:ok, count}
  end

  ## --- Status ---

  @doc """
  What the settings UI shows about the SMTP runner.

    * `:mode` - the stored mode; `:api_available` - whether this core has the
      machine API a runner needs
    * `:state` - `:never_connected`, `:online` (seen within three times
      `idle_poll_s`) or `:offline`. For the built-in runner (mode `local`) see
      `local_responding?/3`: it works in bursts and rests with an empty queue, so
      silence alone is not a fault
    * `:runner` - the row of the runner of the stored mode as a map (`nil` before any
      contact): the built-in runner in the mode `local`, otherwise the latest runner
      with an API key
    * `:port25_blocked`, `:paused` (`%{reason:, until:}` or `nil`)
    * `:mail_from`, `:mail_from_source`, `:mail_from_missing`
    * `:owner` - whose key the runner works with: `nil`, or `%{key_uuid:,
      key_name:, user_uuid:, email:, name:, active:, emails_permission:, warning:}`;
      `warning` is `nil`, `:key_revoked`, `:key_expired`, `:owner_inactive` or
      `:no_emails_permission` (the runner will stop, issue a new token);
      `emails_permission` is whether the owner can still hold the runner scope, that
      is, still holds the `emails` permission
    * `:queue` - `%{queued:, leased:}`
  """
  @spec status(DateTime.t()) :: map()
  def status(now \\ UtilsDate.utc_now()) do
    mode = Config.smtp_mode_setting()
    runner = latest(mode)
    queue = SmtpQueue.counts()
    {mail_from, source} = Config.smtp_mail_from()

    %{
      mode: mode,
      api_available: Config.machine_api_available?(),
      state: state(runner, queue, now),
      runner: runner && Map.take(runner, runner_fields()),
      port25_blocked: match?(%Runner{port25: "blocked"}, runner),
      paused: paused(runner, now),
      mail_from: mail_from,
      mail_from_source: source,
      mail_from_missing: is_nil(mail_from),
      owner: owner(mode, runner),
      queue: queue
    }
  end

  defp runner_fields,
    do:
      ~w(uuid api_key_uuid name version os public_ip helo_auto port25 port25_checked_at last_seen_at jobs_done last_error paused_until pause_reason)a

  defp latest("local"), do: repo().get_by(Runner, api_key_uuid: @local_key)

  defp latest(_mode) do
    repo().one(
      from(r in Runner,
        where: r.api_key_uuid != ^@local_key,
        order_by: [desc_nulls_last: r.last_seen_at, desc: r.inserted_at],
        limit: 1
      )
    )
  end

  defp state(nil, _queue, _now), do: :never_connected
  defp state(%Runner{last_seen_at: nil}, _queue, _now), do: :never_connected

  defp state(%Runner{last_seen_at: seen} = runner, queue, now) do
    online? = if local?(runner), do: local_responding?(seen, now, queue), else: online?(seen, now)
    if online?, do: :online, else: :offline
  end

  @doc """
  Whether the built-in runner (mode `local`) is doing its job: it ran a cycle within the
  last ten minutes, or nothing waits for it (it rests when the queue is empty).
  `queue` is `%{queued:, leased:}`.
  """
  @spec local_responding?(DateTime.t() | nil, DateTime.t(), %{
          queued: non_neg_integer(),
          leased: non_neg_integer()
        }) :: boolean()
  def local_responding?(seen, now, %{queued: queued, leased: leased}) do
    queued + leased == 0 or
      (match?(%DateTime{}, seen) and DateTime.diff(now, seen, :second) < @local_stall_s)
  end

  @doc """
  Whether a runner last seen at `seen` is online at `now`: it was seen within three
  times `idle_poll_s` (the pause it takes on an empty answer). The UI asks again as time
  passes without reading the row.
  """
  @spec online?(DateTime.t() | nil, DateTime.t(), pos_integer()) :: boolean()
  def online?(seen, now, idle_poll_s \\ Config.idle_poll_s())
  def online?(nil, _now, _idle_poll_s), do: false

  def online?(%DateTime{} = seen, now, idle_poll_s),
    do: DateTime.diff(now, seen, :second) < @online_factor * idle_poll_s

  defp paused(%Runner{paused_until: %DateTime{} = until, pause_reason: reason}, now) do
    if DateTime.compare(until, now) == :gt, do: %{reason: reason, until: until}
  end

  defp paused(_runner, _now), do: nil

  @doc """
  Why a `claim` hands out nothing, as `%{reason:, until:}`, or `nil` when the runner is
  not paused.
  """
  @spec pause_of(Runner.t(), DateTime.t()) ::
          %{reason: String.t() | nil, until: DateTime.t()} | nil
  def pause_of(%Runner{} = runner, now), do: paused(runner, now)

  ## --- The key's owner ---

  defp owner("local", _runner), do: nil

  # The owner of the runner's own key. Before the first connection there is no runner
  # row, and after a new token was issued the row still points at the revoked key: both
  # show the owner of the live runner key, as soon as one exists.
  defp owner(_mode, runner) do
    own = runner && owner_of_key(runner)

    case own do
      %{warning: warning} when warning not in [:key_revoked, :key_expired] -> own
      _ -> active_key_owner() || own
    end
  end

  defp owner_of_key(%Runner{api_key_uuid: @local_key}), do: nil

  defp owner_of_key(%Runner{api_key_uuid: key_uuid}) do
    if Config.machine_api_available?(), do: key_owner(key_uuid)
  rescue
    _ -> nil
  end

  defp active_key_owner do
    with true <- Config.machine_api_available?(),
         [key | _] <- RunnerKeys.active() do
      key_owner(key.uuid)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp key_owner(key_uuid) do
    alias PhoenixKit.API.Keys
    alias PhoenixKit.Users.Auth

    with %{} = key <- Keys.get_key(key_uuid),
         %{} = user <- Auth.get_user(key.user_uuid) do
      active = user.is_active != false
      permitted = active and @scope in Keys.allowed_scopes_for(user)

      %{
        key_uuid: key.uuid,
        key_name: key.name,
        user_uuid: user.uuid,
        email: user.email,
        name:
          [user.first_name, user.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" "),
        active: active,
        emails_permission: permitted,
        warning: warning(Keys.dead_reason(key), active, permitted)
      }
    else
      _ -> nil
    end
  end

  defp warning(:revoked, _active, _permitted), do: :key_revoked
  defp warning(:expired, _active, _permitted), do: :key_expired
  defp warning(nil, false, _permitted), do: :owner_inactive
  defp warning(nil, true, false), do: :no_emails_permission
  defp warning(nil, true, true), do: nil

  ## --- The self-test host ---

  @doc """
  The host the runner's port 25 self-test connects to: the setting
  `email_verify_smtp_selftest_host` when set, otherwise the first mail host of the
  `MAIL FROM` domain, otherwise of the site's own host - a server that expects
  our traffic, never someone else's. `nil` when none can be found.
  """
  @spec selftest_host() :: String.t() | nil
  def selftest_host do
    Config.smtp_selftest_host_setting() || first_mx(mail_from_domain()) || first_mx(site_host())
  end

  defp mail_from_domain do
    case Config.smtp_mail_from() do
      {address, _source} when is_binary(address) -> address |> String.split("@") |> List.last()
      _ -> nil
    end
  end

  defp site_host do
    Routes.base_url() |> URI.parse() |> Map.get(:host)
  rescue
    _ -> nil
  end

  defp first_mx(domain) when is_binary(domain) and domain != "" do
    case Pipeline.resolve_mx(String.downcase(domain), []) do
      {{:ok, %{hosts: [%{host: host} | _]}}, _source} -> host
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp first_mx(_domain), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
