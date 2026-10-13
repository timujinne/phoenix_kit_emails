defmodule PhoenixKit.Modules.Emails.SQSPollingJob do
  @moduledoc """
  Oban worker for polling AWS SQS queue for email events.

  This is the sole SQS poller: an Oban-based approach that allows dynamic
  enabling/disabling without an application restart (see `SQSPollingManager`).

  ## Architecture

  ```
  AWS SES → SNS Topic → SQS Queue → SQSPollingJob (Oban) → SQSProcessor → Database
  ```

  ## Multi-account cycle

  One Oban chain, N accounts polled inside each cycle — the shape
  `BrevoPollingJob` already uses, deliberately copied rather than
  generalised. An "account" here is an `aws_ses` Integrations connection
  referenced by an enabled `SendProfile` (see
  `PhoenixKit.Modules.Emails.AwsIntegrations`), carrying its OWN queue URL
  and its OWN credentials — an SES account can only publish events to a
  queue it owns, so polling account A's queue with account B's keys is not
  a degraded mode, it is silence.

  Per-account pipeline settings live in `aws_tracking:<integration_uuid>`
  (see `Emails.get_aws_tracking/1`). Two paths stay alive underneath:

  - **No active `aws_ses` SendProfile at all** — the legacy single-queue
    deployment (env-var or plain-Settings credentials, no profile system).
    The global `aws_sqs_queue_url` + `get_aws_*` credentials are polled
    exactly as before.
  - **An active account with no `aws_tracking:` entry of its own** —
    inherits the global `aws_sqs_queue_url`, but only when the globals can
    be attributed to it unambiguously: it is the account
    `emails_aws_integration_uuid` selects, or it is the only active account.
    With two-plus unattributed accounts the globals describe one queue and
    nothing says whose, so those accounts are skipped (and logged) until
    the operator configures them per-account, rather than having several
    accounts race on one queue with mismatched keys.

  A misconfigured account (credentials that no longer resolve) backs the
  WHOLE cycle off to `@misconfig_backoff_ms`, matching `BrevoPollingJob` —
  a deliberate simplification: one shared cadence, no per-account state.
  An account merely missing a queue URL is not "misconfigured" in that
  sense — it is skipped at full cadence, since a half-configured second
  account must not slow event delivery for a working first one.

  ### Cycle duration with N accounts

  Accounts are polled sequentially and each long-poll waits up to
  `@default_long_poll_timeout` seconds, so a quiet cycle over N accounts
  takes about N x 20s. That does NOT put the self-scheduling chain at risk:
  this worker does not override `c:Oban.Worker.timeout/1`, and Oban's
  default is `:infinity` — there is no deadline that could kill the job
  mid-cycle and hand the chain to Oban's retry machinery. (Adding one would
  be actively harmful: a killed cycle is retried by Oban WHILE
  `schedule_next_poll/1` has already queued a successor, which is how you
  get two chains.)

  What it does cost is latency and a queue slot: `sqs_polling` is
  concurrency 1, so the next tick starts one interval after this cycle
  ENDS, not after it began. With a handful of accounts that is the
  difference between a 5s and a ~25s effective cadence — acceptable, and
  self-correcting in the sense that a busy queue returns immediately rather
  than waiting out the long-poll. If it ever stops being acceptable, the
  fix is parallelism or one chain per account (phase 2), not a timeout.

  ## Features

  - **Dynamic Configuration**: Automatically responds to settings changes without restart
  - **Oban Integration**: Uses Oban's job system for reliable background processing
  - **Self-Scheduling**: Each job schedules the next polling cycle
  - **Batch Processing**: Process up to 10 messages at a time
  - **Error Handling**: Retry logic with Dead Letter Queue
  - **Settings-Based Control**: Polling can be enabled/disabled via Settings

  ## Configuration

  All settings are retrieved from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable polling (checked before each cycle)
  - `sqs_polling_interval_ms` - interval between polling cycles
  - `sqs_max_messages_per_poll` - maximum messages per batch
  - `sqs_visibility_timeout` - time for message processing
  - `aws_sqs_queue_url` - SQS queue URL
  - `aws_region` - AWS region

  ## Usage

      # Enable polling (starts first job)
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

      # Disable polling (stops scheduling new jobs)
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()

      # Trigger immediate polling
      PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()

      # Check status
      PhoenixKit.Modules.Emails.SQSPollingManager.status()

  ## Oban Queue Configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        repo: YourApp.Repo,
        queues: [
          sqs_polling: 1  # Only one concurrent polling job
        ]

  ## Implementation Notes

  - Uses Oban's own `unique:` (not a manual delete-then-insert) to keep
    exactly one future job queued — see the `unique:` option below for
    the full reasoning; it's the subtle part of this module.
  - Schedules next job only if polling is enabled
  - Uses `SQSProcessor` for event processing

  ## Why `unique: [period: :infinity, states: [:scheduled]]`, not more

  This looks under-specified at first glance — Oban's own unique-states
  groups (`:incomplete`, or the full default) include `:executing`,
  `:available`, `:retryable` too. Each of those is excluded here for a
  concrete reason, not an oversight:

  - **`:executing` must never be in this worker-level list.** The chain
    works by a currently-`:executing` job inserting its own successor
    from inside `perform/1`. Oban marks a job `:executing` in the DB
    *before* calling `perform/1`, and its unique-conflict check has no
    self-exclusion — an insert of the same worker/args while `:executing`
    is in `states` finds that job's *own* row as the "existing" match and
    no-ops against it instead of creating a new `:scheduled` row. The
    chain would silently stop advancing every single cycle, not just on
    a crash. (A job orphaned in `:executing` by a hard kill would make
    this permanent, on top of merely stalling per-cycle.)
  - **A wider list (e.g. adding `:available`) fails the build.** Oban's
    `use Oban.Worker, unique: [...]` option is checked at compile time
    (`Oban.Worker`'s `__after_compile__` hook → `Job.warn_unique/1`): any
    `:states` list other than the exact literal `[:scheduled]` that
    doesn't cover every "incomplete" state (`:scheduled`, `:available`,
    `:executing`, `:retryable`, `:suspended`) emits a compiler warning
    ("may break uniqueness"), which `--warnings-as-errors` turns into a
    build failure. `[:scheduled]` alone is Oban's own special-cased
    exception to that check (see `Job.warn_unique/1`) — it is the *only*
    partial list that both compiles clean and excludes `:executing`.
  - `[:scheduled]` is exactly enough for THIS insert: self-scheduled jobs
    always land in `:scheduled` (interval >= 1000ms ⇒ schedule_in >= 1s,
    never `:available`), so it dedups the self-reschedule chain against
    itself with no manual delete step. `period: :infinity` (not a short
    window) makes that hold regardless of how long the configured
    interval is — a short window only caught *near-simultaneous* double
    inserts; the old delete-then-insert dance existed specifically to
    catch the case a short window couldn't (two chains a full interval
    apart). An unconditional `:infinity` unique check removes the need
    for that dance entirely.
  - The immediate job from `SQSPollingManager.enable_polling/0` /
    `poll_now/0` is a **different** insert with its own **per-call**
    `unique:`/`replace:` override (`states: [:available, :scheduled]`) —
    see `SQSPollingManager`'s `insert_poll_job/0` and
    `insert_forced_poll_job/0`. A per-call override on `new/2` does NOT
    go through the compile-time check above (only the worker-level `use`
    default does), so it's free to cover `:available` too. It still
    excludes `:executing` for the same self-conflict reason. `poll_now/0`
    additionally carries `args: %{"forced" => true}`, which puts it in a
    separate uniqueness namespace (Oban matches on args) so a manual poll
    never moves the regular chain's next tick.
  - Concurrency is capped at 1 by the queue, so parallel *execution* is
    already impossible; `unique:` is what prevents parallel *chains*.
  """

  use Oban.Worker,
    queue: :sqs_polling,
    max_attempts: 3,
    unique: [period: :infinity, states: [:scheduled]]

  require Logger

  import Ecto.Query

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.AwsIntegrations
  alias PhoenixKit.Modules.Emails.SQSProcessor

  @default_long_poll_timeout 20

  # Back-off interval used when the config is (recoverably) invalid, so a
  # misconfigured system is not polled at the full rate while it keeps failing.
  @misconfig_backoff_ms 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # `forced: true` (SQSPollingManager.poll_now/0) bypasses the
    # sqs_polling_enabled toggle specifically — an operator asking for
    # events right now shouldn't be silently ignored just because the
    # background chain is off — but never bypasses Emails.enabled?/0, the
    # SES-events switch, or the sender-aware gate (see
    # pollable_ignoring_toggle?/0). schedule_next_poll/1 re-checks
    # should_poll?/0 on its own, so a forced run while the toggle is off
    # still runs once without resurrecting the self-scheduling chain.
    # Mirrors BrevoPollingJob.perform/1.
    forced? = Map.get(args || %{}, "forced", false)

    # Check if polling is enabled before processing
    if should_poll?() or (forced? and pollable_ignoring_toggle?()) do
      Logger.debug("SQS Polling Job: Starting polling cycle")

      # Global tuning knobs (interval, batch size, visibility timeout) plus
      # the legacy single-queue fields; the per-account queue URL and
      # credentials are resolved per account inside run_cycle/2.
      config = Emails.get_sqs_config()

      # The self-scheduling chain owns continuation; the poll interval IS the
      # retry cadence. We ALWAYS schedule the next cycle while polling is enabled
      # and return :ok — never {:error}. Returning {:error} would either spawn a
      # duplicate chain (Oban retry + self-schedule both firing) or, once the 3
      # Oban attempts are exhausted on a sustained outage, let the chain die
      # permanently until an app restart. A transient receive error simply
      # retries on the next scheduled poll; a recoverable misconfiguration backs
      # off but keeps the chain alive so it resumes once fixed.
      # unique: [period: :infinity, states: [:scheduled]] on the worker (see
      # moduledoc) keeps this to exactly one chain — no manual cleanup needed.
      next_interval =
        case validate_configuration(config) do
          :ok ->
            warn_about_unconfigured_accounts()
            prune_stale_aws_tracking(AwsIntegrations.active_integration_uuids())

            case run_cycle(pollable_accounts(), config) do
              :misconfigured -> @misconfig_backoff_ms
              :ok -> config.polling_interval_ms
            end

          {:error, reason} ->
            Logger.error("SQS Polling Job: Invalid configuration - #{reason}")
            @misconfig_backoff_ms
        end

      schedule_next_poll(next_interval)
      :ok
    else
      Logger.debug("SQS Polling Job: Polling disabled, skipping cycle")
      :ok
    end
  end

  # A failed polling cycle does not fail the Oban job (the chain self-continues);
  # we log it loudly so a sustained outage stays observable.
  defp log_cycle_result({:ok, _}), do: :ok

  defp log_cycle_result({:error, reason}) do
    Logger.error("SQS Polling Job: Polling cycle failed", %{reason: inspect(reason)})
    :ok
  end

  @doc """
  Returns the Oban `worker` column value for this job.

  Single source of truth for callers that query `Oban.Job` by worker name
  (e.g. `SQSPollingManager`), so they never drift from `inspect(__MODULE__)`.
  """
  @spec worker_name() :: String.t()
  def worker_name, do: inspect(__MODULE__)

  defp get_repo do
    PhoenixKit.RepoHelper.repo()
  end

  ## --- Private Functions ---

  @doc false
  # Check if polling should be performed. Not `defp` so the sender-aware
  # gate can be unit-tested directly without a real SQS/network round trip.
  def should_poll? do
    Emails.sqs_polling_enabled?() and pollable_ignoring_toggle?()
  end

  @doc false
  # Everything the poller needs EXCEPT the sqs_polling_enabled toggle: the
  # system switch, the SES-events switch, a queue to poll, and the
  # sender-aware gate below. A forced (poll_now/0) cycle bypasses the
  # toggle but never these — mirroring BrevoPollingJob, whose `forced?`
  # bypasses brevo_events_enabled but never Emails.enabled?/0 or its
  # profile gate. This is exactly `EventTracker.eligible?/0`'s SES
  # definition (SQSPollingManager.eligible?/0 delegates here) — not `defp`
  # for that reuse, same testability rationale as `should_poll?/0` above.
  def pollable_ignoring_toggle? do
    Emails.enabled?() and
      Emails.ses_events_enabled?() and
      queue_url_configured?() and
      ses_actively_configured?()
  end

  @doc false
  # Every account this poller would poll if the opt-out list were empty,
  # as `%{integration_uuid: uuid | nil, queue_url: url, region: region | nil}`.
  # `integration_uuid: nil` is the legacy single-queue deployment (no
  # `aws_ses` SendProfile exists at all) — see the moduledoc.
  #
  # Only accounts that actually have a queue URL are returned, which is what
  # makes this usable as the eligibility gate below: "there is at least one
  # account with somewhere to poll". Deliberately NOT filtered by the
  # per-account opt-out — mirroring Brevo, whose eligible?/0 also ignores
  # exclusions, so opting every account out pauses the polling instead of
  # tearing the chain down and needing a reconcile to bring it back.
  #
  # Not `defp` so the resolution can be unit-tested without a network round
  # trip — same rationale as `should_poll?/0`.
  @spec configured_accounts() :: [
          %{
            integration_uuid: String.t() | nil,
            queue_url: String.t(),
            region: String.t() | nil,
            inherits_legacy?: boolean()
          }
        ]
  def configured_accounts do
    case AwsIntegrations.active_integration_uuids() do
      [] ->
        legacy_accounts()

      uuids ->
        case Enum.flat_map(uuids, &account_for(&1, uuids)) do
          # Nothing attributable YET. This is the shape an upgrade lands in
          # when two or more `aws_ses` SendProfiles are active and none of
          # them is the account `emails_aws_integration_uuid` selects: no
          # account can claim the global queue, so per-account resolution
          # yields nothing. Returning [] here would make eligible?/0 false and
          # the reconciler would CANCEL a chain that was polling perfectly
          # well a minute ago — an upgrade silently switching event tracking
          # off. Falling back to the global queue keeps exactly the
          # pre-upgrade behaviour (one queue, the global credentials) until
          # the operator configures the first account, at which point this
          # branch stops being reached.
          [] -> legacy_accounts()
          accounts -> accounts
        end
    end
  end

  @doc false
  # True when active SES accounts exist but none of them has a queue of its
  # own — the state `configured_accounts/0` covers by falling back to the
  # global queue. Surfaced so the poller can log it and the settings UI can
  # show it: it is a working-but-unfinished configuration, and silence is how
  # it would stay unfinished.
  @spec accounts_awaiting_configuration() :: [String.t()]
  def accounts_awaiting_configuration do
    case AwsIntegrations.active_integration_uuids() do
      [] ->
        []

      uuids ->
        configured =
          uuids
          |> Enum.flat_map(&account_for(&1, uuids))
          |> MapSet.new(& &1.integration_uuid)

        Enum.reject(uuids, &MapSet.member?(configured, &1))
    end
  end

  @doc false
  # `configured_accounts/0` minus the operator's per-account opt-out (see
  # `Emails.get_sqs_polling_excluded_integrations/0`) — what a cycle
  # actually polls. The legacy account has no uuid and so can never be
  # excluded; there is nothing to name it by, and the opt-out UI cannot
  # show it either.
  def pollable_accounts do
    excluded = MapSet.new(Emails.get_sqs_polling_excluded_integrations())

    configured_accounts()
    |> Enum.reject(fn account ->
      is_binary(account.integration_uuid) and MapSet.member?(excluded, account.integration_uuid)
    end)
    |> honour_opt_out_in_legacy_fallback(excluded)
  end

  # The legacy account has no uuid, so the opt-out list cannot name it — which
  # meant that opting every account out did NOT stop polling: the accounts
  # dropped away, `configured_accounts/0` fell back to the unattributed legacy
  # queue, and the operator's "poll nothing" turned into "poll the one queue I
  # was trying to stop polling".
  #
  # Only the FALLBACK is suppressed. A genuine legacy deployment — no active
  # `aws_ses` SendProfile at all, so nothing to opt out of — is untouched,
  # because there is no excluded account to have caused the fallback.
  defp honour_opt_out_in_legacy_fallback([%{integration_uuid: nil}] = accounts, excluded) do
    active = AwsIntegrations.active_integration_uuids()

    if active != [] and Enum.all?(active, &MapSet.member?(excluded, &1)) do
      Logger.debug(
        "SQS Polling Job: every account is opted out, not falling back to the legacy queue"
      )

      []
    else
      accounts
    end
  end

  defp honour_opt_out_in_legacy_fallback(accounts, _excluded), do: accounts

  defp legacy_accounts do
    url = Emails.get_sqs_queue_url()

    if is_binary(url) and url != "" do
      [%{integration_uuid: nil, queue_url: url, region: nil, inherits_legacy?: true}]
    else
      []
    end
  end

  defp account_for(uuid, active_uuids) do
    tracking = Emails.get_aws_tracking(uuid)
    inherits_legacy? = legacy_attributable?(uuid, active_uuids)

    queue_url =
      (tracking && tracking.queue_url) || (inherits_legacy? && Emails.get_sqs_queue_url()) || nil

    if is_binary(queue_url) and queue_url != "" do
      [
        %{
          integration_uuid: uuid,
          queue_url: queue_url,
          region: tracking && tracking.region,
          inherits_legacy?: inherits_legacy?
        }
      ]
    else
      Logger.debug("SQS Polling Job: no queue configured for integration #{uuid}, skipping")
      []
    end
  end

  # The global settings — one queue URL, one set of `get_aws_*` credentials —
  # describe exactly ONE account, so they can only be inherited by an account
  # they unambiguously belong to: the one `emails_aws_integration_uuid`
  # selects, or the only active account there is. See the moduledoc's
  # "Multi-account cycle" for why the ambiguous case is skipped rather than
  # fanned out.
  # Deliberately NOT a disjunction. With `emails_aws_integration_uuid` pointing
  # at account A and a single active account B, `or` handed B the globals —
  # A's queue URL, and through `build_aws_config/1` A's credentials. One
  # account polling another's queue with another's keys is the exact failure
  # this whole change exists to remove.
  #
  # An explicit selection is an answer, so it is THE answer; only when there is
  # no selection does "the only active account" get to claim the globals.
  defp legacy_attributable?(uuid, active_uuids) do
    case Emails.selected_aws_integration_uuid() do
      selected when is_binary(selected) -> uuid == selected
      _ -> match?([_single], active_uuids)
    end
  end

  # `aws_tracking:<uuid>` outlives the connection it describes, so a
  # deleted SES connection would leave its queue settings in Settings
  # forever (the same accumulation `BrevoPollingJob.prune_stale_watermarks/1`
  # prevents for watermarks).
  #
  # Pruned against the connections that EXIST, not against the active
  # (profile-referenced, non-excluded) set Brevo uses: a watermark is a
  # regenerable cursor, while this is operator-entered configuration —
  # disabling a SendProfile for an afternoon, or opting an account out of
  # polling, must not silently discard its queue URLs.
  #
  # Two things keep this off the hot path. It runs on a 5-second cadence by
  # default, and `list_connections/2` DECRYPTS every returned connection:
  #
  #   * the candidate set is computed first, from a plain Settings prefix
  #     read, and every uuid that is already an active account is dropped.
  #     In the steady state that leaves nothing and the decrypting query
  #     never runs at all.
  #   * `owner: :any` matches how the active set is resolved
  #     (`Integrations.get_credentials/2` and `get_integration_by_uuid/2` both
  #     default to `:any`). The default `owner: :system` would classify every
  #     USER-owned connection as non-existent and delete its tracking row on
  #     the next cycle — a live account's queue settings vanishing on a timer.
  defp prune_stale_aws_tracking(active_uuids) do
    candidates = Emails.list_aws_tracking_integration_uuids() -- active_uuids

    if candidates != [] do
      known =
        "aws_ses"
        |> Integrations.list_connections(owner: :any)
        |> MapSet.new(& &1.uuid)

      candidates
      |> Enum.reject(&MapSet.member?(known, &1))
      |> Enum.each(fn stale_uuid ->
        Emails.delete_aws_tracking(stale_uuid)

        Logger.info(
          "SQS Polling Job: pruned stale tracking settings for integration #{stale_uuid} " <>
            "(connection no longer exists)"
        )
      end)
    end
  end

  defp warn_about_unconfigured_accounts do
    case accounts_awaiting_configuration() do
      [] ->
        :ok

      uuids ->
        Logger.warning(
          "SQS Polling Job: #{length(uuids)} active SES account(s) have no queue of their own " <>
            "(#{Enum.join(uuids, ", ")}) — falling back to the single global queue. Configure " <>
            "each account under Settings -> Email Sending -> Delivery Event Tracking -> expand the Amazon SES row."
        )
    end
  end

  @doc false
  # One cycle over every account. Returns :misconfigured if ANY account's
  # credentials failed to resolve, which backs the whole chain off — see
  # the moduledoc. Not `defp` so the backoff decision is unit-testable with
  # a hand-built account list and no network — same rationale as
  # `should_poll?/0`.
  def run_cycle([], _config) do
    Logger.debug("SQS Polling Job: no accounts to poll this cycle")
    :ok
  end

  def run_cycle(accounts, config) do
    results = Enum.map(accounts, &poll_account(&1, config))

    if Enum.any?(results, &(&1 == :misconfigured)) do
      Logger.error("SQS Polling Job: one or more accounts misconfigured, backing off")
      :misconfigured
    else
      :ok
    end
  end

  @spec poll_account(map(), map()) :: :ok | :misconfigured
  defp poll_account(account, config) do
    case resolve_aws_config(account, config) do
      {:ok, aws_config} ->
        config
        |> Map.put(:queue_url, account.queue_url)
        |> perform_polling_cycle(aws_config)
        |> log_cycle_result()

        :ok

      {:error, reason} ->
        Logger.error(
          "SQS Polling Job: could not resolve credentials for integration " <>
            "#{account.integration_uuid}",
          %{reason: inspect(reason)}
        )

        :misconfigured
    end
  end

  @doc false
  # Legacy account: the process-wide `get_aws_*` resolution (selected
  # connection, then legacy Settings, then env) — unchanged behaviour for a
  # deployment that never adopted SendProfiles. Public (`@doc false`) so the
  # credential fallback can be asserted without a network round trip.
  def resolve_aws_config(account, config \\ nil)

  def resolve_aws_config(%{integration_uuid: nil}, config),
    do: {:ok, build_aws_config(config || Emails.get_sqs_config())}

  # Per-account: this connection's own keys and ONE region.
  #
  # The region used to be settable in three places — on the connection, on the
  # tracking row, and globally — and the tracking row won. That is how an
  # account ends up signing requests for a region its queue does not live in
  # (the install this was found on had a queue in eu-north-1 and a tracking row
  # saying eu-central-1). The queue URL is the only self-evident answer: it
  # names the region the queue is actually in. Everything else falls back to the
  # connection, which is where the credentials that must be valid there live.
  # A stored tracking region is deliberately ignored.
  def resolve_aws_config(%{integration_uuid: uuid} = account, config) do
    config = config || Emails.get_sqs_config()

    case AwsIntegrations.resolve_credentials(uuid) do
      {:ok, creds} ->
        case region_from_queue_url(account.queue_url) || creds.region do
          nil ->
            {:error, :missing_region}

          resolved_region ->
            {:ok,
             [
               access_key_id: creds.access_key,
               secret_access_key: creds.secret_key,
               region: resolved_region
             ]}
        end

      # The connection stores no credentials. That is NOT necessarily a
      # misconfiguration: a deployment can keep its AWS keys in environment
      # variables, an instance profile, or the legacy `aws_access_key_id`
      # Settings, with the Integrations connection existing only so a
      # SendProfile can point at it. Before this fallback such an account
      # resolved to {:error, :missing_credentials} forever — the cycle backed
      # off, the queue was never polled, and event tracking stopped silently
      # on upgrade.
      #
      # The fallback applies under exactly the rule that governs the global
      # QUEUE too (`legacy_attributable?/2`): the globals describe one
      # account, so only the account they can be attributed to may use them.
      # `build_aws_config/1` returning [] is meaningful, not empty — it tells
      # ExAws to resolve credentials itself, which is the whole point for an
      # env/instance-profile deployment.
      {:error, :missing_credentials} = error ->
        if account.inherits_legacy? do
          Logger.debug(
            "SQS Polling Job: integration #{uuid} stores no credentials, " <>
              "using the legacy AWS credential resolution"
          )

          {:ok, build_aws_config(config)}
        else
          error
        end
    end
  end

  # Carries the precondition that used to live in the supervisor's own
  # `has_sqs_configuration?/0` boot gate. Once boot started going through
  # `EventTrackerReconciler.reconcile/0`, eligible?/0 became the only gate
  # left, and without this a deployment with SES credentials and the toggle
  # on but no queue URL would start a chain at boot, have the reconcile Cron
  # resurrect it every couple of minutes, and log "no queue" on the
  # @misconfig_backoff_ms cadence forever — while the admin panel, seeing
  # live jobs, called it :active / "Running normally". Folded into
  # eligible?/0 the same state reads :idle_no_integration, which is what it
  # is.
  #
  # Multi-account form of the same precondition: "there is at least one
  # account with a queue to poll" (see `configured_accounts/0`). Keeping it
  # a plain existence check is the point — weakening it to "some account
  # exists" would reintroduce exactly the chain-with-nowhere-to-poll bug it
  # was added for.
  #
  # Public (`@doc false`) for the settings panel, which names WHICH of the
  # gate's conditions is the one stopping collection — same reuse rationale
  # as `should_poll?/0` above.
  @spec queue_url_configured?() :: boolean()
  def queue_url_configured? do
    configured_accounts() != []
  end

  @doc false
  # Public for the settings panel: it tells the operator WHICH of the gate's
  # conditions is the one stopping collection, and "no active sender" is one of
  # them. Same reuse rationale as `should_poll?/0` above.
  #
  # Sender-aware gate, mirroring the (parallel) Brevo poller design — see
  # PR #18 (BrevoPollingJob isn't on main yet, so there's nothing to
  # literally reference here). SQS credentials being *reachable* isn't
  # the same as SES actually being the thing sending mail right now. Two
  # ways to count as "actively configured":
  #
  #   - `Emails.aws_configured?/0` — the explicit override: SQS polling
  #     predates the SendProfile system, and plenty of deployments still
  #     configure SES directly (legacy `aws_access_key_id`/
  #     `aws_secret_access_key` Settings, env vars, or a bare `aws_ses`
  #     Integrations connection with no SendProfile pointed at it at
  #     all). Requiring a SendProfile unconditionally would silently stop
  #     polling for every one of those pre-existing setups. Checked
  #     first — it's the cached lookup (`PhoenixKit.Cache`-backed, see
  #     `Emails.aws_ses_credentials/0`), cheaper than the DB round trip
  #     below.
  #   - an enabled SendProfile pointed at an `"aws_ses"` integration (the
  #     current, profile-based way to wire up a sender).
  @spec ses_actively_configured?() :: boolean()
  def ses_actively_configured? do
    Emails.aws_configured?() or has_enabled_ses_send_profile?()
  end

  defp has_enabled_ses_send_profile? do
    SendProfile
    |> where([sp], sp.enabled == true and sp.provider_kind == "aws_ses")
    |> limit(1)
    |> get_repo().exists?()
  end

  # Validate the CYCLE-WIDE tuning knobs. The queue URL is deliberately not
  # checked here any more: it is per-account now, and an account without one
  # is dropped by `configured_accounts/0` before the cycle ever sees it —
  # while `queue_url_configured?/0` keeps the chain itself from existing
  # when no account has a queue at all. A single account's missing queue
  # must not back off the accounts that do have one.
  defp validate_configuration(config) do
    cond do
      not is_integer(config.polling_interval_ms) or config.polling_interval_ms < 1000 ->
        # Sub-second intervals round down to schedule_in: 0 (Oban schedules in
        # whole seconds), causing a back-to-back poll loop. Mirror
        # SQSPollingManager.set_polling_interval/1's >= 1000 guard.
        {:error, "Invalid polling interval (must be >= 1000ms)"}

      not is_integer(config.max_messages_per_poll) or
        config.max_messages_per_poll <= 0 or
          config.max_messages_per_poll > 10 ->
        {:error, "Invalid max messages per poll (must be 1-10)"}

      not is_integer(config.visibility_timeout) or config.visibility_timeout <= 0 ->
        {:error, "Invalid visibility timeout"}

      true ->
        :ok
    end
  end

  # Perform one polling cycle against ONE account's queue. `aws_config` is
  # that account's resolved ExAws credentials (see `resolve_aws_config/2`),
  # passed in rather than derived from `config` so the two can differ per
  # account within a single cycle.
  defp perform_polling_cycle(config, aws_config) do
    _start_time = System.monotonic_time(:millisecond)

    case receive_messages(config, aws_config) do
      {:ok, [_ | _] = messages} ->
        Logger.info("SQS Polling Job: Received #{length(messages)} messages")

        processing_start = System.monotonic_time(:millisecond)
        processed_count = process_messages(messages, config, aws_config)
        processing_time = System.monotonic_time(:millisecond) - processing_start

        Logger.info(
          "SQS Polling Job: Processed #{processed_count}/#{length(messages)} messages in #{processing_time}ms"
        )

        {:ok,
         %{processed: processed_count, total: length(messages), duration_ms: processing_time}}

      {:ok, []} ->
        Logger.debug("SQS Polling Job: No messages in queue")
        {:ok, %{processed: 0, total: 0}}

      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to receive messages", %{
          reason: inspect(reason),
          queue_url: config.queue_url
        })

        {:error, reason}
    end
  end

  # Receive messages from SQS queue
  defp receive_messages(config, aws_config) do
    request =
      ExAws.SQS.receive_message(
        config.queue_url,
        max_number_of_messages: config.max_messages_per_poll,
        wait_time_seconds: @default_long_poll_timeout,
        visibility_timeout: config.visibility_timeout,
        message_attribute_names: [:all],
        attribute_names: [:all]
      )

    case ExAws.request(request, aws_config) do
      {:ok, %{"Messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{"messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, _response} ->
        {:ok, []}

      {:error, error} ->
        Logger.error("SQS Polling Job: ExAws request failed", %{
          error: inspect(error),
          queue_url: config.queue_url
        })

        {:error, error}
    end
  end

  # Process message list in parallel
  defp process_messages(messages, config, aws_config) do
    tasks =
      Enum.map(messages, fn message ->
        Task.async(fn ->
          process_single_message(message, config.queue_url, aws_config)
        end)
      end)

    # yield_many (not await_many) so a slow task can't RAISE and abort the whole
    # perform/1: a raised timeout would trigger an Oban retry and tear down the
    # in-flight delete_message calls, re-cycling messages. Tasks that yield
    # {:ok, true} count as processed; un-yielded/timed-out ones are shut down and
    # treated as not-processed, so their messages simply re-receive normally
    # after the SQS visibility timeout.
    tasks
    |> Task.yield_many(30_000)
    |> Enum.count(fn {task, result} ->
      case result || Task.shutdown(task, :brutal_kill) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  # Process a single message.
  #
  # ExAws.SQS may return messages with either string keys ("ReceiptHandle") or
  # atom keys (:receipt_handle, from the `%{body: %{messages: [...]}}` parsed
  # shape that receive_messages/1 also accepts). Read both, otherwise the
  # receipt handle comes back nil and delete_message/3 silently fails, leaving
  # the message to be re-received forever.
  defp process_single_message(message, queue_url, aws_config) do
    message_id = message["MessageId"] || message[:message_id]
    receipt_handle = message["ReceiptHandle"] || message[:receipt_handle]

    with {:ok, event_data} <- SQSProcessor.parse_sns_message(message),
         {:ok, _result} <- SQSProcessor.process_email_event(event_data),
         :ok <- delete_message(queue_url, receipt_handle, aws_config) do
      true
    else
      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to process message", %{
          message_id: message_id,
          reason: inspect(reason)
        })

        false
    end
  end

  # Delete processed message from queue. Returns the failure (instead of
  # swallowing it as :ok) so a message that wasn't actually deleted is not
  # counted as processed — the silent :ok previously hid a nil-receipt-handle
  # bug that made messages re-cycle forever.
  defp delete_message(_queue_url, nil, _aws_config) do
    Logger.error("SQS Polling Job: Missing receipt handle, cannot delete message")
    {:error, :missing_receipt_handle}
  end

  defp delete_message(queue_url, receipt_handle, aws_config) do
    ExAws.SQS.delete_message(queue_url, receipt_handle)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("SQS Polling Job: Failed to delete message", %{
          error: inspect(error),
          queue_url: queue_url
        })

        {:error, error}
    end
  end

  @doc false
  # Schedule next polling job. Relies entirely on the worker's own
  # `unique: [period: :infinity, states: [:scheduled]]` (see moduledoc) to
  # guarantee exactly one queued future job — no manual delete-then-insert.
  # A conflict here (job.conflict? == true) means another :scheduled job
  # already exists; that's the expected, harmless steady state (e.g. this
  # cycle racing an enable_polling/poll_now insert), not an error. Not
  # `defp` so the dedup behavior is unit-testable directly — same
  # rationale as `should_poll?/0` above.
  def schedule_next_poll(interval_ms) do
    if should_poll?() do
      # Oban schedule_in is in whole SECONDS — div(interval_ms, 1000) is 0 for
      # any 1..999ms interval, which would queue the next poll immediately and
      # spin a back-to-back loop. Floor at 1s. (validate_configuration/1 already
      # rejects sub-second intervals; this is a defensive backstop.)
      %{}
      |> __MODULE__.new(schedule_in: max(div(interval_ms, 1000), 1))
      |> Oban.insert()
      |> case do
        {:ok, %Oban.Job{conflict?: true}} ->
          Logger.debug("SQS Polling Job: Next poll already scheduled, skipping duplicate insert")

          :ok

        {:ok, _job} ->
          Logger.debug("SQS Polling Job: Next poll scheduled in #{interval_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("SQS Polling Job: Failed to schedule next poll", %{
            reason: inspect(reason)
          })

          :ok
      end
    else
      Logger.debug("SQS Polling Job: Polling disabled, not scheduling next poll")
      :ok
    end
  end

  # The region an SQS queue lives in, read off the queue URL.
  #
  # Load-bearing, not a nicety: `ex_aws_sqs` puts the QueueUrl in the request
  # BODY and builds the host from the configured region, so a wrong region does
  # not "still find the queue" — every receive fails. And the failure is quiet,
  # because a failed receive is logged and the cycle still returns `:ok`, so it
  # repeats forever at full cadence with nothing in the UI to show for it.
  # The URL is the one place that always knows the truth.
  @doc false
  # Public: the settings UI shows the same derived region it polls with, so the
  # operator and the poller can never disagree about where a queue lives.
  def region_from_queue_url(url) when is_binary(url) do
    case Regex.run(~r{^https://sqs\.([a-z0-9-]+)\.amazonaws\.com/}, url) do
      [_, region] -> region
      _ -> nil
    end
  end

  def region_from_queue_url(_url), do: nil

  # Build AWS configuration for the LEGACY single-account path from the
  # process-wide `get_aws_*` resolution. Per-account credentials do not come
  # through here — see `resolve_aws_config/2`. An empty list means "let
  # ExAws resolve credentials itself" (env vars, instance profile), which is
  # exactly what an env-configured deployment relies on.
  defp build_aws_config(config) do
    if is_binary(config.aws_access_key_id) and config.aws_access_key_id != "" and
         is_binary(config.aws_secret_access_key) and config.aws_secret_access_key != "" and
         is_binary(config.aws_region) and config.aws_region != "" do
      [
        access_key_id: String.trim(config.aws_access_key_id),
        secret_access_key: String.trim(config.aws_secret_access_key),
        region: String.trim(config.aws_region)
      ]
    else
      []
    end
  end
end
