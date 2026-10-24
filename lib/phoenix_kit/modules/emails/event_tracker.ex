defmodule PhoenixKit.Modules.Emails.EventTracker do
  @moduledoc """
  Behaviour every provider delivery-event tracker implements (SES, Brevo,
  future Mailgun/…). See
  `dev_docs/specs/2026-07-26-email-event-tracking-universalization-spec.md`
  §4.1 for the full design rationale.

  The lifecycle invariant every registered tracker must satisfy:

  > iff `should_run?/1` (== `eligible?/1 and enabled?/1`), exactly one
  > self-scheduling Oban chain is queued for `worker/1`; otherwise none.

  `EventTrackerReconciler` is what actually enforces this — a tracker
  only needs to answer the callbacks below honestly.

  ## `eligible?/1` vs `enabled?/1` — not the same gate

  `eligible?/1` folds every *feature/source* gate: "does a working event
  source exist for this provider at all". `enabled?/1` is *only* the
  operator's polling on/off switch. Conflating them was the SES poller's
  original bug (`SQSPollingJob.should_poll?/0` gates on three things —
  `Emails.enabled?()`, `email_ses_events`, AND `sqs_polling_enabled` — not
  two): `email_ses_events` is a feature flag ("is SES event tracking a
  thing here at all"), which belongs in `eligible?/1`, not folded into
  the polling toggle. Getting this split right is what lets the admin
  panel (P2) distinguish "Idle — no integration" (eligible? false) from
  "Off" (enabled? false) as genuinely different states.

  ### The one sanctioned exception: SES turning `email_ses_events` ON

  The split above says an eligibility flag must not move with the
  operator's toggle. `SQSPollingManager.enable_polling/0` moves one
  anyway: it writes `email_ses_events` to `true` alongside
  `sqs_polling_enabled`. That is a deliberate exception, not a leak of
  the old conflation, and it is one-directional.

  The reason is a dead end an operator could not see out of. Both flags
  are needed before SES events arrive, but they live in two different
  settings sections; an install where `email_ses_events` had been
  switched off answered a freshly flipped Tracking toggle with "Idle —
  no integration" and no hint that the missing piece was a checkbox on
  another page. Enabling states an intent about the *install* ("SES
  event tracking is a thing here"), which the eligibility flag is
  exactly the right place to record — so enabling asserts it rather
  than demanding the operator find it.

  `disable_polling/0` does NOT clear the flag, and must not start. Three
  reasons: "stop polling for now" is a statement about the operator, not
  about the install, so the eligibility answer is unchanged; the same
  flag gates the SNS webhook path (`Emails.Web.WebhookController`),
  which does not poll anything and would go silent for no stated reason;
  and clearing it would erase the difference between an install that
  never tracked SES and one that paused. The flag keeps its own toggle
  in the Email Tracking settings section
  (`Web.SettingsSections.EmailTracking`) for an operator who does mean
  "no SES events at all".

  The narrow shape of the exception is what keeps `state/1` honest: an
  eligibility flag may be asserted by an operator action that logically
  implies it, never retracted by one that does not.
  """

  @typedoc "A tracker module implementing this behaviour."
  @type t :: module()

  @doc """
  The discriminator — matches `SendProfile.provider_kind` (`"aws_ses"`, `"brevo_api"`, …).
  """
  @callback provider_kind() :: String.t()

  @doc """
  Human-readable name for the admin panel ("Amazon SES", "Brevo").
  """
  @callback label() :: String.t()

  @doc """
  Is there a working event source this tracker can poll right now? Folds
  every feature/source gate (integration presence, feature flags) —
  everything EXCEPT the operator's polling on/off switch.
  """
  @callback eligible?() :: boolean()

  @doc "The operator's polling master toggle only (not eligibility)."
  @callback enabled?() :: boolean()

  @doc """
  Run one poll cycle synchronously, outside of Oban's own scheduling —
  for callers that want an immediate, in-process cycle (e.g. a future
  admin panel "Poll now" action) rather than queueing a job. Delegates to
  the existing `*PollingJob.perform/1` logic; the self-scheduling job/
  worker itself is unchanged by this behaviour.
  """
  @callback poll_cycle(context :: map()) :: :ok | {:error, term()}

  @doc "Cadence (ms) the next self-schedule should use — the tracker's own configured interval."
  @callback interval_ms() :: pos_integer()

  @doc """
  The floor `set_polling_interval/1` (the informal Manager API — see
  `EventTrackerRegistry`) enforces for this tracker, e.g. SES's `1_000`
  vs Brevo's `30_000` (a lower bound driven by the provider's own API,
  not a policy choice this behaviour makes). Not optional — every
  tracker's interval editor needs *some* real floor to show as the
  input's client-side `min`; a wrong/missing one either lets an operator
  type a value the server will reject anyway, or falsely floors a
  provider that could safely poll faster (dual-review P2 fix 2/5).
  """
  @callback min_interval_ms() :: pos_integer()

  @doc "The Oban worker module backing this tracker's self-scheduling chain."
  @callback worker() :: module()

  @doc """
  Admin panel's Integration-column count ("2 active integrations").
  **Optional** — trackers without a working default (there isn't one:
  every tracker has *some* meaningful count) may still skip it; a
  tracker that doesn't define this gets `1`/`0` from `eligible?/0`
  instead (see `integration_count/1`). Defining it explicitly is
  strongly recommended whenever "how many" means something more precise
  than a bare yes/no (Brevo's multi-account case).
  """
  @callback integration_count() :: non_neg_integer()

  @doc """
  Per-integration opt-out list for the admin panel's Accounts column:
  `{uuid, name, polled?}` for every currently-active account. **Optional**
  — only define this if the provider has a genuine multi-account opt-out
  concept (Brevo does; SES doesn't). A tracker that skips it gets `nil`
  (see `accounts/1`), which the panel reads as "not applicable" and
  renders as a plain placeholder in the Accounts cell rather than a
  checkbox list.
  """
  @callback accounts() :: [{uuid :: String.t(), name :: String.t(), polled? :: boolean()}]

  @doc """
  Flips one integration's polling opt-out (see `accounts/0`). **Optional**
  — a tracker that skips it (because it skipped `accounts/0` too) gets a
  safe no-op (see `toggle_account_polling/2`) instead of an
  `UndefinedFunctionError` from a stale/forged panel action.
  """
  @callback toggle_account_polling(uuid :: String.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  This tracker's own durable "last completed cycle" timestamp, when it
  keeps one. **Optional** — a tracker that skips it falls back to the
  generic Oban-history derivation (see `last_polled_at/1`), which is
  correct but only as long as the completed job still exists. Define
  this whenever the tracker's polling interval can outlive
  `Oban.Plugins.Pruner`'s `max_age` (Brevo's floor alone is 30s against
  a 60s default), or the panel's Last-poll column reads "Never polled
  yet" for a perfectly healthy chain.
  """
  @callback last_polled_at() :: DateTime.t() | nil

  @doc """
  The `Phoenix.LiveComponent` rendering this tracker's own provider-specific
  settings, shown inside its expanded row in the "Delivery event tracking"
  panel. **Optional** — a tracker that skips it (or returns `nil`) gets a
  plain "no separate settings" note instead (see `settings_component/1`).

  Only the module is returned, never `{module, assigns}`: the panel has no
  provider-specific data to hand down, and the component is required to load
  its own state in `update/2` — a caller-supplied assigns map would be a
  second source of truth for the same settings, and the panel would have to
  know what every provider needs in order to build it.
  """
  @callback settings_component() :: module() | nil

  @optional_callbacks integration_count: 0,
                      accounts: 0,
                      toggle_account_polling: 1,
                      last_polled_at: 0,
                      settings_component: 0

  @doc """
  `eligible?() and enabled?()` — the single condition the reconciler
  enforces "exactly one chain" against. Not a callback (every tracker
  gets this for free from the two it does implement) — takes the tracker
  MODULE, not an instance, since trackers are stateless behaviours.
  """
  @spec should_run?(t()) :: boolean()
  def should_run?(tracker) when is_atom(tracker) do
    tracker.eligible?() and tracker.enabled?()
  end

  @typedoc "The admin panel's four-word state vocabulary (spec §5)."
  @type state :: :active | :idle_no_integration | :off | :stalled

  @doc """
  Derives the admin panel's State column — exactly one of `:active`,
  `:idle_no_integration`, `:off`, `:stalled` (spec §5).

  `:stalled` (`should_run?` true, zero jobs across
  `available|scheduled|executing`) is the one state that needs a false-
  positive guard: a healthy chain inserts its own successor
  *synchronously inside `perform`*, before returning, so at every point
  in a normal cycle at least one row is `executing` (the current job,
  which hasn't finished yet) or `scheduled`/`available` (its
  already-inserted successor) — never both empty at once. Counting
  `executing` (via `pending_jobs_count/1`) is what closes that window;
  without it, reading queued-only states would flicker `:stalled` on
  every single cycle. A transient miss beyond that (e.g. reconcile
  hasn't run yet since a `SendProfile` was just added — no PubSub for
  that today, spec §4.3) self-clears within one reconcile Cron tick;
  this function makes no attempt to mask that window client-side, since
  doing so would also hide a genuinely stalled chain.
  """
  @spec state(t()) :: state()
  def state(tracker) when is_atom(tracker) do
    cond do
      not tracker.enabled?() -> :off
      not tracker.eligible?() -> :idle_no_integration
      pending_jobs_count(tracker) > 0 -> :active
      true -> :stalled
    end
  end

  @doc """
  Oban job count for this tracker's `worker/0`, across exactly
  `available|scheduled|executing` — the "is a chain alive" health check
  (spec §5's "Queued" column and `state/1`'s `:stalled` detection both
  use this; **never** queued-only, see `state/1`'s moduledoc).
  """
  @spec pending_jobs_count(t()) :: non_neg_integer()
  def pending_jobs_count(tracker) when is_atom(tracker) do
    import Ecto.Query

    worker_name = inspect(tracker.worker())
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end

  @doc """
  Timestamp this tracker's chain last finished a cycle: the tracker's own
  `last_polled_at/0` when it defines that optional callback, otherwise
  derived generically from Oban's own job history (the last `completed`
  job for `worker/0`), which needs zero extra plumbing per tracker. A
  no-op cycle (nothing to fetch) still completes normally either way, so
  this reads as "the chain is alive and ticking", matching what the
  per-provider `*_last_polled_at` settings already intended.

  > #### The Oban-history fallback is bounded by the Pruner {: .warning}
  >
  > `Oban.Plugins.Pruner` deletes `completed` rows older than its
  > `max_age` (60s by default), so the fallback can only ever see a
  > cycle that finished inside that window — a tracker polling less
  > often than the Pruner keeps history reads as `nil` ("Never polled
  > yet") even while perfectly healthy. That is exactly why
  > `last_polled_at/0` exists as a callback: SES's default 5s cadence
  > is comfortably inside any sane prune window, Brevo's 30s floor
  > (and realistically much longer) is not, so `BrevoPollingManager`
  > defines it against the durable `brevo_last_polled_at` setting its
  > job already writes every cycle.
  """
  @spec last_polled_at(t()) :: DateTime.t() | nil
  def last_polled_at(tracker) when is_atom(tracker) do
    if function_exported?(tracker, :last_polled_at, 0) do
      tracker.last_polled_at()
    else
      last_completed_job_at(tracker)
    end
  end

  defp last_completed_job_at(tracker) do
    import Ecto.Query

    worker_name = inspect(tracker.worker())
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job,
      where: j.worker == ^worker_name,
      where: j.state == "completed",
      order_by: [desc: j.completed_at],
      limit: 1,
      select: j.completed_at
    )
    |> repo.one()
  rescue
    _ -> nil
  end

  @doc """
  `integration_count/0` if the tracker defines it, otherwise a safe
  default derived from `eligible?/0` (`1` when eligible, `0` when not) —
  the single guarded call site the admin panel uses, so a tracker that
  skips the optional callback can never crash the panel (spec #56 P2
  review: this used to be called unconditionally from the panel itself).
  """
  @spec integration_count(t()) :: non_neg_integer()
  def integration_count(tracker) when is_atom(tracker) do
    if function_exported?(tracker, :integration_count, 0) do
      tracker.integration_count()
    else
      if tracker.eligible?(), do: 1, else: 0
    end
  end

  @doc """
  `accounts/0` if the tracker defines it, otherwise `nil` ("not
  applicable" — no per-integration opt-out concept for this provider).
  """
  @spec accounts(t()) :: [{String.t(), String.t(), boolean()}] | nil
  def accounts(tracker) when is_atom(tracker) do
    if function_exported?(tracker, :accounts, 0), do: tracker.accounts(), else: nil
  end

  @doc """
  `toggle_account_polling/1` if the tracker defines it, otherwise a
  no-op success — guards against a stale or forged panel action
  targeting a tracker with no opt-out concept (e.g. SES) ever reaching
  an undefined function and crashing the LiveView.
  """
  @spec toggle_account_polling(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def toggle_account_polling(tracker, uuid) when is_atom(tracker) do
    if function_exported?(tracker, :toggle_account_polling, 1) do
      tracker.toggle_account_polling(uuid)
    else
      {:ok, :not_applicable}
    end
  end

  @doc """
  `settings_component/0` if the tracker defines it, otherwise `nil` — the
  single guarded call site the panel uses, so a provider with no settings
  of its own (and a Mailgun implementation that never heard of this
  callback) renders the "no separate settings" note rather than crashing
  the panel with an `UndefinedFunctionError`.
  """
  @spec settings_component(t()) :: module() | nil
  def settings_component(tracker) when is_atom(tracker) do
    # `Code.ensure_loaded?/1` first: under interactive code loading an
    # unloaded tracker answers `false` to `function_exported?/3`, and the row
    # would quietly render "no settings of its own" for a provider that has
    # them.
    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :settings_component, 0) do
      tracker.settings_component()
    else
      nil
    end
  end
end
