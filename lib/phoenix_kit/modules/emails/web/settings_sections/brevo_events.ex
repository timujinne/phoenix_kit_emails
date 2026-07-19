defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.BrevoEvents do
  @moduledoc """
  "Brevo Events" section on the core Email Sending settings page
  (`/admin/settings/email-sending`).

  Covers the module's Brevo-specific concern: polling Brevo's
  transactional-email events API for delivery/bounce/open/click/etc.
  tracking (there is no push/webhook path for Brevo the way SES has
  SNS→SQS). Contributed via
  `PhoenixKit.Modules.Emails.email_settings_sections/0`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoIntegrations
  alias PhoenixKit.Modules.Emails.BrevoPollingManager

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :brevo_events_enabled) do
        socket
      else
        socket
        |> assign(:brevo_events_enabled, Emails.brevo_events_enabled?())
        |> assign(:brevo_polling_interval_ms, Emails.get_brevo_polling_interval())
        |> assign(:brevo_status, BrevoPollingManager.status())
        |> assign(:brevo_accounts, load_brevo_accounts())
        |> assign(:polling_now, false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_brevo_events", _params, socket) do
    new_enabled = !socket.assigns.brevo_events_enabled

    result =
      if new_enabled do
        BrevoPollingManager.enable_polling()
      else
        BrevoPollingManager.disable_polling()
      end

    success? =
      case result do
        :ok -> true
        {:ok, _} -> true
        _ -> false
      end

    if success? do
      socket =
        socket
        |> assign(:brevo_events_enabled, new_enabled)
        |> assign(:brevo_status, BrevoPollingManager.status())
        |> put_flash(
          :info,
          if(new_enabled,
            do: gettext("Brevo event polling enabled"),
            else: gettext("Brevo event polling disabled")
          )
        )

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Failed to update Brevo event polling"))}
    end
  end

  def handle_event("update_brevo_polling_interval", params, socket) do
    value = Map.get(params, "interval") || Map.get(params, "value")

    case Integer.parse(value || "") do
      {interval_ms, _} when interval_ms >= 30_000 ->
        case BrevoPollingManager.set_polling_interval(interval_ms) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:brevo_polling_interval_ms, interval_ms)
              |> put_flash(
                :info,
                gettext("Brevo polling interval updated to %{ms}ms", ms: interval_ms)
              )

            {:noreply, socket}

          {:error, _reason} ->
            {:noreply,
             put_flash(socket, :error, gettext("Failed to update Brevo polling interval"))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a value of at least 30000ms"))}
    end
  end

  def handle_event("poll_brevo_now", _params, socket) do
    socket = assign(socket, :polling_now, true)

    case BrevoPollingManager.poll_now() do
      {:ok, _job} ->
        socket =
          socket
          |> assign(:polling_now, false)
          |> assign(:brevo_status, BrevoPollingManager.status())
          |> put_flash(:info, gettext("Brevo poll triggered"))

        {:noreply, socket}

      {:error, _reason} ->
        socket =
          socket
          |> assign(:polling_now, false)
          |> put_flash(:error, gettext("Failed to trigger Brevo poll"))

        {:noreply, socket}
    end
  end

  def handle_event("toggle_brevo_account_polling", %{"uuid" => uuid}, socket) do
    excluded = Emails.get_brevo_polling_excluded_integrations()

    new_excluded =
      if uuid in excluded, do: List.delete(excluded, uuid), else: [uuid | excluded]

    case Emails.set_brevo_polling_excluded_integrations(new_excluded) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:brevo_status, BrevoPollingManager.status())
          |> assign(:brevo_accounts, load_brevo_accounts())

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update account polling"))}
    end
  end

  # `{uuid, name, polled?}` for every currently-active Brevo account, for
  # the per-account opt-out checkbox list.
  defp load_brevo_accounts do
    excluded = MapSet.new(Emails.get_brevo_polling_excluded_integrations())

    BrevoIntegrations.active_integrations_with_names()
    |> Enum.map(fn {uuid, name} -> {uuid, name, not MapSet.member?(excluded, uuid)} end)
  end
end
