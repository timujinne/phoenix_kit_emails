defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs do
  @moduledoc """
  The Amazon SES half of the "Delivery event tracking" panel: everything
  SES-specific behind the expanded `aws_ses` row — which Integrations
  connection supplies SES/SQS credentials, the per-account queues, one-click
  infrastructure setup, and the SQS worker's tuning knobs.

  Reached through `SQSPollingManager.settings_component/0`, not through
  `c:PhoenixKit.Module.email_settings_sections/0`. It used to be a
  third section on the settings page, listed as a peer of the tracker table
  while actually being the detail of one of its rows: it repeated that
  table's "is collection on" answer, and nothing on the page said which
  row it belonged to.

  Loads everything it renders in `update/2` and takes no assigns but `id`,
  which is what lets the panel render it without knowing anything about SES.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.AWS.InfrastructureSetup
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.AwsIntegrations
  alias PhoenixKit.Modules.Emails.EventTrackerReconciler
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking
  alias PhoenixKit.Settings

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :tracking_accounts) do
        socket
      else
        email_config = Emails.get_config()

        socket
        |> assign(:mailer_status, Utils.mailer_adapter_status())
        |> assign(:aws_configured, Emails.aws_configured?())
        |> assign(:sqs_max_messages_per_poll, email_config.sqs_max_messages_per_poll)
        |> assign(:sqs_visibility_timeout, email_config.sqs_visibility_timeout)
        # The only global `aws_*` setting still read by this panel, and only
        # to warn that sending is running on it. The rest are no longer shown
        # or editable here: they are the SAME fields the per-account rows
        # carry, and the account rows are the one place to change them. The
        # CODE fallback is untouched — poller and interceptor still read the
        # globals for an install that has not moved to per-account tracking.
        |> assign(:legacy_credentials?, legacy_credentials?())
        |> assign(:aws_ses_connections, Integrations.list_connections("aws_ses"))
        |> assign(
          :selected_aws_integration_uuid,
          Settings.get_setting("emails_aws_integration_uuid", "")
        )
        |> assign_tracking_accounts()
        |> assign(:setting_up_account, nil)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("update_max_messages", params, socket) do
    value = Map.get(params, "max_messages") || Map.get(params, "value")

    case Utils.parse_int(value, nil, min: 1, max: 10) do
      max_messages when is_integer(max_messages) ->
        case Emails.set_sqs_max_messages(max_messages) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_max_messages_per_poll, max_messages)
              |> put_flash(
                :info,
                gettext("SQS max messages updated to %{count}", count: max_messages)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update SQS max messages"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(socket, :error, gettext("Please enter a valid number between 1 and 10"))

        {:noreply, socket}
    end
  end

  def handle_event("update_visibility_timeout", params, socket) do
    value = Map.get(params, "timeout") || Map.get(params, "value")

    case Utils.parse_int(value, nil, min: 30, max: 43_200) do
      timeout when is_integer(timeout) ->
        case Emails.set_sqs_visibility_timeout(timeout) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:sqs_visibility_timeout, timeout)
              |> put_flash(
                :info,
                gettext("SQS visibility timeout updated to %{seconds} seconds", seconds: timeout)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update SQS visibility timeout"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Please enter a valid number between 30 and 43200 seconds")
          )

        {:noreply, socket}
    end
  end

  def handle_event("assign_tracking_account", %{"uuid" => ""}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Select an Amazon SES connection to add"))}
  end

  def handle_event("assign_tracking_account", %{"uuid" => uuid}, socket) do
    if known_connection?(socket, uuid) do
      case Emails.set_aws_tracking(uuid, %{}) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> after_tracking_change()
           |> put_flash(:info, gettext("Account added to event tracking"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to add account"))}
      end
    else
      # Not an aws_ses connection this page could have offered — a stale tab
      # or a forged phx-value. Ignored rather than written.
      {:noreply, socket}
    end
  end

  def handle_event("unassign_tracking_account", %{"uuid" => uuid}, socket) do
    if known_connection?(socket, uuid) do
      do_unassign_tracking_account(uuid, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_tracking_account", %{"uuid" => uuid} = params, socket) do
    attrs = Map.get(params, "tracking", %{})

    if known_connection?(socket, uuid) do
      # A crafted non-map "tracking" is a failed save, not a FunctionClauseError
      # out of set_aws_tracking/2.
      case is_map(attrs) && Emails.set_aws_tracking(uuid, attrs) do
        {:ok, _setting} ->
          {:noreply,
           socket
           |> after_tracking_change()
           |> put_flash(:info, gettext("Account tracking settings saved"))}

        _failed ->
          {:noreply, put_flash(socket, :error, gettext("Failed to save account settings"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("setup_account_infrastructure", %{"uuid" => uuid}, socket) do
    if known_connection?(socket, uuid) do
      {:noreply, run_account_setup(assign(socket, :setting_up_account, uuid), uuid)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("assign_aws_integration", %{"uuid" => uuid}, socket)
      when uuid != "" do
    # Every other handler here validates; this one did not, and it writes the
    # setting that decides which account may inherit the global queue. A forged
    # phx-value pointing at nothing would leave the globals attributable to no
    # active account, and polling would stop with the panel still calling it
    # healthy.
    if known_connection?(socket, uuid) do
      do_assign_aws_integration(uuid, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("assign_aws_integration", %{"uuid" => uuid}, socket) do
    do_assign_aws_integration(uuid, socket)
  end

  defp do_unassign_tracking_account(uuid, socket) do
    case Emails.delete_aws_tracking(uuid) do
      {:error, :not_found} ->
        {:noreply, after_tracking_change(socket)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove account"))}

      _ok ->
        {:noreply,
         socket
         |> after_tracking_change()
         |> put_flash(:info, gettext("Account removed from event tracking"))}
    end
  end

  defp do_assign_aws_integration(uuid, socket) do
    # An empty uuid means "back to legacy" — clear the setting instead of
    # writing an empty value (the key isn't in Setting's optional-value
    # allowlist, so an empty-string write would fail changeset validation).
    # That allowlist is a core Setting concern, out of scope for this
    # package — the delete-vs-empty-string asymmetry with other settings
    # here is intentional, not an oversight, until core grows a way to add
    # a key to it from outside core itself.
    result =
      if uuid == "" do
        case Settings.delete_setting("emails_aws_integration_uuid") do
          {:error, :not_found} -> {:ok, nil}
          other -> other
        end
      else
        Settings.update_setting("emails_aws_integration_uuid", uuid)
      end

    case result do
      {:ok, _} ->
        # The next get_aws_*/0 call must see the newly selected connection
        # (or the legacy fallback) immediately, not after the credentials
        # cache's TTL — see Emails.invalidate_aws_credentials_cache/0.
        Emails.invalidate_aws_credentials_cache()

        # This setting decides which account may inherit the global queue
        # (SQSPollingJob.configured_accounts/0), so changing it can make the
        # SES tracker newly eligible or newly ineligible. Same reasoning as
        # after_tracking_change/1 and the Delivery Event Tracking toggle:
        # without a reconcile the chain is only corrected on the next cron
        # tick, or never on a host that skipped wiring the cron.
        EventTrackerReconciler.reconcile_tracker(SQSPollingManager)

        socket =
          socket
          |> assign(:selected_aws_integration_uuid, uuid)
          |> assign_tracking_accounts()
          |> put_flash(:info, gettext("SES credentials source updated"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update SES credentials source"))}
    end
  end

  # Rows for the per-account tracking list, plus the connections that don't
  # have one yet (what the "add account" picker offers). Both derived from
  # the same `list_connections("aws_ses")` read the credentials-source
  # picker already does, so a connection can never appear in both.
  defp assign_tracking_accounts(socket) do
    # Reads the connection list itself rather than trusting an assign: this
    # runs from every write handler, and one of them (assign_aws_integration)
    # is reachable on a socket that never went through update/2.
    connections = Integrations.list_connections("aws_ses")
    assigned = MapSet.new(Emails.list_aws_tracking_integration_uuids())
    active = MapSet.new(AwsIntegrations.active_integration_uuids())

    rows =
      connections
      |> Enum.filter(&MapSet.member?(assigned, &1.uuid))
      |> Enum.map(fn connection ->
        %{
          uuid: connection.uuid,
          name: connection.name,
          active?: MapSet.member?(active, connection.uuid),
          tracking: Emails.get_aws_tracking(connection.uuid) || %{}
        }
      end)

    # Active accounts with no queue of their own: the poller is still running,
    # but on the single legacy queue rather than per account (see
    # SQSPollingJob.configured_accounts/0). Named here because the alternative
    # is an operator who upgraded, sees "Running normally", and has no idea
    # half their accounts are not being polled.
    awaiting =
      SQSPollingJob.accounts_awaiting_configuration()
      |> Enum.map(fn uuid ->
        case Enum.find(connections, &(&1.uuid == uuid)) do
          %{name: name} -> name
          _ -> uuid
        end
      end)

    socket
    |> assign(:aws_ses_connections, connections)
    |> assign(:accounts_awaiting_configuration, awaiting)
    |> assign(:tracking_accounts, rows)
    |> assign(:legacy_queue_url, legacy_queue_url())
    |> assign(
      :unassigned_connections,
      Enum.reject(connections, &MapSet.member?(assigned, &1.uuid))
    )
  end

  # Whether that queue is being polled and, when it is not, WHY — one read of
  # the gate, decomposed into the very conditions `SQSPollingJob.should_poll?/0`
  # ands together, in its order. Both the verdict and the sentence come from
  # this single call: asking `should_poll?/0` first and then re-deriving the
  # reason evaluated the same conditions twice per render (including a second
  # SendProfile query), and left a window in which a switch flipped between the
  # two reads could produce "not polled" with no reason to give.
  #
  # Read at RENDER time, never stored. The switch that decides it lives in the
  # tracker row above this panel, whose toggle does not re-run this component's
  # `update/2` (its assigns are seeded once, behind a guard). A cached copy
  # would sit here claiming the queue is polled long after collection was
  # switched off, which is the very statement this notice exists to get right.
  @spec legacy_queue_poll_state() ::
          :polled | :system_off | :events_off | :tracking_off | :no_queue | :no_sender
  defp legacy_queue_poll_state do
    cond do
      not Emails.enabled?() -> :system_off
      not Emails.ses_events_enabled?() -> :events_off
      not Emails.sqs_polling_enabled?() -> :tracking_off
      not SQSPollingJob.queue_url_configured?() -> :no_queue
      not SQSPollingJob.ses_actively_configured?() -> :no_sender
      true -> :polled
    end
  end

  # The sentence for that state. Each names the switch to go and flip, rather
  # than asking the reader to work out which of five things is off. No
  # catch-all clause: the states above enumerate every condition of the gate,
  # so a new one would fail to match here loudly instead of rendering a vague
  # sentence that is quietly wrong.
  defp poll_state_text(:polled, url) do
    gettext("Polling the legacy global queue: %{url}", url: url)
  end

  defp poll_state_text(:system_off, url) do
    gettext("One global queue is configured, but the email system is off: %{url}", url: url)
  end

  defp poll_state_text(:events_off, url) do
    gettext("One global queue is configured, but SES event tracking is off: %{url}", url: url)
  end

  defp poll_state_text(:tracking_off, url) do
    gettext(
      "One global queue is configured; switch Tracking on in the row above to poll it: %{url}",
      url: url
    )
  end

  # `@legacy_queue_url` is resolved once in `update/2`, behind a guard, while
  # the gate is read on every render — so this is the queue setting being
  # cleared while the panel sits open. The URL is the one this panel still
  # believes in, hence "no longer".
  defp poll_state_text(:no_queue, url) do
    gettext(
      "This queue is no longer configured — reload the page to see the current setup: %{url}",
      url: url
    )
  end

  defp poll_state_text(:no_sender, url) do
    gettext(
      "One global queue is configured, but no enabled send profile uses Amazon SES: %{url}",
      url: url
    )
  end

  # The single pre-per-account `aws_sqs_queue_url`, or nil when this install
  # has none. Resolved here rather than in the template because it is only
  # ever read alongside `tracking_accounts` — an install with no per-account
  # rows AND a global queue is the one the panel used to describe as having
  # nothing configured while the poller was happily reading that queue.
  #
  # Blank-as-nil, not just nil-as-nil: `get_sqs_queue_url/0` returns whatever
  # is stored, and a setting cleared through the UI is an empty string, not a
  # deleted row.
  defp legacy_queue_url do
    case Emails.get_sqs_queue_url() do
      url when is_binary(url) ->
        trimmed = String.trim(url)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  # Reload the rows AND reconcile the SES tracker — see the handlers above.
  # Credentials are invalidated too: a per-account setup run can have
  # rewritten the region the send path resolves for this connection.
  defp after_tracking_change(socket) do
    EventTrackerReconciler.reconcile_tracker(SQSPollingManager)
    Emails.invalidate_aws_credentials_cache()

    # Everything reached through here changes what the tracker ROW above this
    # panel says — the account count, and whether the tracker is eligible at
    # all. A child's event does not re-run the parent's update/2, so adding the
    # first account left the row one pixel higher still reporting "no
    # integration" until something else redrew it. The panel is a detail of
    # that row; it has to tell the row when it changed.
    notify_parent(socket)

    socket
    |> assign_tracking_accounts()
    |> assign(:setting_up_account, nil)
  end

  defp notify_parent(socket) do
    case socket.assigns[:parent_id] do
      nil -> :ok
      parent_id -> send_update(DeliveryEventTracking, id: parent_id)
    end
  end

  # Scoped `owner: :any`, matching how the poller and the send-path attribution
  # resolve accounts (`Integrations.get_credentials/2` and
  # `get_integration_by_uuid/2` both default to `:any`). Validating against the
  # narrower `:system` list would reject a USER-owned connection that the
  # poller happily uses — a guard stricter than the thing it guards is a bug
  # wearing a safety jacket.
  defp known_connection?(socket, uuid) do
    connections =
      Map.get(socket.assigns, :aws_ses_connections) ||
        Integrations.list_connections("aws_ses", owner: :any)

    Enum.any?(connections, &(&1.uuid == uuid))
  end

  # Creates the SNS topic / SQS queue / DLQ / configuration set in THIS
  # account (its own keys, not the globally selected connection's) and
  # stores the result under `aws_tracking:<uuid>` instead of the global
  # `aws_*` settings — the whole point of the per-account model: resources
  # created with account A's credentials only ever exist in account A.
  defp run_account_setup(socket, uuid) do
    with {:ok, creds} <- AwsIntegrations.resolve_credentials(uuid),
         {:ok, config} <- setup_infrastructure(creds) do
      tracking = %{
        "queue_url" => config["aws_sqs_queue_url"],
        "dlq_url" => config["aws_sqs_dlq_url"],
        "queue_arn" => config["aws_sqs_queue_arn"],
        "sns_topic_arn" => config["aws_sns_topic_arn"],
        "configuration_set" => config["aws_ses_configuration_set"],
        "region" => config["aws_region"]
      }

      case Emails.set_aws_tracking(uuid, tracking) do
        {:ok, _setting} ->
          socket
          |> after_tracking_change()
          |> put_flash(:info, gettext("AWS infrastructure created for this account"))

        {:error, _reason} ->
          socket
          |> assign(:setting_up_account, nil)
          |> put_flash(
            :error,
            gettext("Infrastructure created but the settings could not be saved")
          )
      end
    else
      {:error, :missing_credentials} ->
        socket
        |> assign(:setting_up_account, nil)
        |> put_flash(
          :error,
          gettext("This connection has no AWS credentials — add them in Settings → Integrations")
        )

      {:error, :missing_region} ->
        socket
        |> assign(:setting_up_account, nil)
        |> put_flash(
          :error,
          gettext(
            "This connection has no AWS region — set it in Settings → Integrations before creating infrastructure"
          )
        )

      {:error, step, reason} ->
        socket
        |> assign(:setting_up_account, nil)
        |> put_flash(
          :error,
          gettext("AWS setup failed at step %{step}: %{reason}", step: step, reason: reason)
        )
    end
  end

  # A missing region is refused, never guessed. `InfrastructureSetup.run/1`
  # creates an SNS topic, a queue, a DLQ and a configuration set — in a guessed
  # region that is four real AWS resources in the wrong place, invisible to the
  # account that actually sends, and removable only by hand in a console.
  defp setup_infrastructure(%{region: nil}), do: {:error, :missing_region}

  defp setup_infrastructure(creds) do
    InfrastructureSetup.run(
      project_name: project_name(),
      region: creds.region,
      access_key_id: creds.access_key,
      secret_access_key: creds.secret_key
    )
  end

  # Is the send path still running on the global, pre-Integrations key pair?
  defp legacy_credentials? do
    case Settings.get_setting("aws_access_key_id", "") do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp project_name do
    Settings.get_setting("project_title", "myapp")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.trim("-")
  end

  defp mailer_config_snippet(%{config_app: app, config_module: mod}) do
    """
    config :#{app}, #{inspect(mod)},
      adapter: Swoosh.Adapters.AmazonSES,
      region: "eu-north-1"
    """
  end
end
