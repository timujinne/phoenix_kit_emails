defmodule PhoenixKit.Modules.Emails.Web.EmailTracking do
  @moduledoc """
  LiveView for email tracking system settings and configuration.

  This module provides a simplified interface for managing core email tracking
  settings, offering quick toggles for essential email system features.

  ## Features

  - **System Toggle**: Enable/disable email tracking system
  - **Body Storage**: Control whether full email bodies are saved
  - **SES Events**: Toggle AWS SES event processing
  - **Retention Settings**: Configure data retention periods

  ## Route

  This LiveView is mounted at `{prefix}/admin/settings/email-tracking` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

  This is a focused settings page for common email tracking configurations.
  For advanced settings (AWS infrastructure, compression, archival, etc.),
  see the main Emails settings page.

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext
  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Modules.Emails

  def mount(params, _session, socket) do
    # Handle locale
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get project title from settings

    # Load email tracking configuration
    email_tracking_config = Emails.get_config()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Email Tracking Settings"))
      |> assign(
        :page_subtitle,
        gettext("Configure email tracking system behavior and data retention")
      )
      |> assign(:email_tracking_enabled, email_tracking_config.enabled)
      |> assign(:email_tracking_save_body, email_tracking_config.save_body)
      |> assign(:email_tracking_ses_events, email_tracking_config.ses_events)
      |> assign(:email_tracking_retention_days, email_tracking_config.retention_days)

    {:ok, socket}
  end

  def handle_event("toggle_email_tracking_save_body", _params, socket) do
    # Toggle email body saving
    new_save_body = !socket.assigns.email_tracking_save_body

    result = Emails.set_save_body(new_save_body)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_tracking_save_body, new_save_body)
          |> put_flash(
            :info,
            if(new_save_body,
              do: gettext("Email body saving enabled"),
              else: gettext("Email body saving disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update email body saving setting"))
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_tracking_ses_events", _params, socket) do
    # Toggle AWS SES events tracking
    new_ses_events = !socket.assigns.email_tracking_ses_events

    result = Emails.set_ses_events(new_ses_events)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_tracking_ses_events, new_ses_events)
          |> put_flash(
            :info,
            if(new_ses_events,
              do: gettext("AWS SES events tracking enabled"),
              else: gettext("AWS SES events tracking disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update AWS SES events tracking"))
        {:noreply, socket}
    end
  end

  def handle_event("update_email_tracking_retention", %{"retention_days" => value}, socket) do
    case Integer.parse(value) do
      {retention_days, _} when retention_days > 0 and retention_days <= 365 ->
        case Emails.set_retention_days(retention_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_tracking_retention_days, retention_days)
              |> put_flash(
                :info,
                gettext("Email retention period updated to %{days} days", days: retention_days)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update email retention period"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(socket, :error, gettext("Please enter a valid number between 1 and 365"))

        {:noreply, socket}
    end
  end
end
