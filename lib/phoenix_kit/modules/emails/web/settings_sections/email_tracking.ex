defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking do
  @moduledoc """
  "Email Tracking" section on the core Email Sending settings page
  (`/admin/settings/email-sending`).

  Covers what to store for each outgoing email (body, headers, sampling
  rate), how long to keep it (retention, compression, S3 archival), and the
  send queue's two switches — plus the system-status card, which reports what
  the module is actually doing rather than what it is configured to do.
  Contributed via `c:PhoenixKit.Module.email_settings_sections/0`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Queue
  alias PhoenixKit.Modules.Emails.Status
  alias PhoenixKit.Modules.Emails.Utils

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # LiveComponent `update/2` runs on mount and on send_update — NOT on this
    # component's own handle_event/3. So the card is refreshed here and again in
    # every event that changes something it displays (see refresh_status/1);
    # a card that keeps showing the pre-toggle value is worse than none.
    socket = refresh_status(socket)

    socket =
      if Map.has_key?(socket.assigns, :email_save_body) do
        socket
      else
        email_config = Emails.get_config()

        socket
        |> assign(:email_enabled, email_config.enabled)
        |> assign(:email_save_body, email_config.save_body)
        |> assign(:email_save_headers, Emails.save_headers_enabled?())
        |> assign(:email_retention_days, email_config.retention_days)
        |> assign(:email_sampling_rate, email_config.sampling_rate)
        |> assign(:email_compress_body, email_config.compress_after_days)
        |> assign(:email_archive_to_s3, email_config.archive_to_s3)
        |> assign(:email_s3_bucket, Emails.get_s3_bucket() || "")
        |> assign(:email_s3_integration, Emails.get_s3_integration() || "")
        |> assign(:s3_connections, s3_connections())
        |> assign(:running_cleanup, false)
        |> assign(:running_compression, false)
        |> assign(:updating_compress_days, false)
      end

    {:ok, socket}
  end

  defp refresh_status(socket), do: assign(socket, :status, Status.summary())

  @impl true
  def handle_event("toggle_email_save_body", _params, socket) do
    new_save_body = !socket.assigns.email_save_body

    case Emails.set_save_body(new_save_body) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_body, new_save_body)
          |> refresh_status()
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

  # The queue's two switches read their current value off @status (refreshed on
  # every event), so there is no separate assign to keep in step.
  def handle_event("toggle_email_queue", _params, socket) do
    new_enabled = !socket.assigns.status.queue.enabled?

    case Queue.set_enabled(new_enabled) do
      {:ok, _setting} ->
        socket =
          socket
          |> refresh_status()
          |> put_flash(
            :info,
            if(new_enabled,
              do: gettext("Outgoing emails are now queued"),
              else: gettext("Outgoing emails are now sent immediately")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update the send queue setting"))}
    end
  end

  def handle_event("toggle_email_queue_auth_mail", _params, socket) do
    new_enabled = !socket.assigns.status.queue.auth_mail?

    case Queue.set_auth_mail_enabled(new_enabled) do
      {:ok, _setting} ->
        socket =
          socket
          |> refresh_status()
          |> put_flash(
            :info,
            if(new_enabled,
              do: gettext("Authentication emails are now queued"),
              else: gettext("Authentication emails are now sent immediately")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update the authentication mail setting"))}
    end
  end

  def handle_event("toggle_email_save_headers", _params, socket) do
    new_save_headers = !socket.assigns.email_save_headers

    case Emails.set_save_headers(new_save_headers) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_headers, new_save_headers)
          |> refresh_status()
          |> put_flash(
            :info,
            if(new_save_headers,
              do: gettext("Email headers saving enabled"),
              else: gettext("Email headers saving disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket =
          put_flash(socket, :error, gettext("Failed to update email headers saving setting"))

        {:noreply, socket}
    end
  end

  def handle_event("update_email_sampling_rate", params, socket) do
    value = Map.get(params, "sampling_rate") || Map.get(params, "value")

    case Utils.parse_int(value, nil, min: 0, max: 100) do
      sampling_rate when is_integer(sampling_rate) ->
        case Emails.set_sampling_rate(sampling_rate) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_sampling_rate, sampling_rate)
              |> refresh_status()
              |> put_flash(
                :info,
                gettext("Email sampling rate updated to %{rate}%", rate: sampling_rate)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, gettext("Failed to update email sampling rate"))
            {:noreply, socket}
        end

      _ ->
        socket =
          put_flash(socket, :error, gettext("Please enter a valid number between 0 and 100"))

        {:noreply, socket}
    end
  end

  def handle_event("update_email_retention", params, socket) do
    value = Map.get(params, "retention_days") || Map.get(params, "value")

    case Utils.parse_int(value, nil, min: 1, max: 365) do
      retention_days when is_integer(retention_days) ->
        case Emails.set_retention_days(retention_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_retention_days, retention_days)
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

  def handle_event("update_compress_days", params, socket) do
    value = Map.get(params, "compress_days") || Map.get(params, "value")

    socket = assign(socket, :updating_compress_days, true)

    case Utils.parse_int(value, nil, min: 7, max: 365) do
      compress_days when is_integer(compress_days) ->
        case Emails.set_compress_after_days(compress_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_compress_body, compress_days)
              |> assign(:updating_compress_days, false)
              |> put_flash(
                :info,
                "✅ " <>
                  gettext("Compression setting updated to %{days} days", days: compress_days)
              )

            {:noreply, socket}

          {:error, _changeset} ->
            socket =
              socket
              |> assign(:updating_compress_days, false)
              |> put_flash(:error, "❌ " <> gettext("Failed to update compression days"))

            {:noreply, socket}
        end

      _ ->
        socket =
          socket
          |> assign(:updating_compress_days, false)
          |> put_flash(
            :error,
            "⚠️ " <> gettext("Please enter a valid number between 7 and 365")
          )

        {:noreply, socket}
    end
  end

  def handle_event("run_cleanup_now", _params, socket) do
    socket = assign(socket, :running_cleanup, true)

    retention_days = socket.assigns.email_retention_days

    task = Task.async(fn -> Emails.cleanup_old_logs(retention_days) end)

    case Task.yield(task, 30_000) || Task.shutdown(task) do
      {:ok, {deleted_count, _}} ->
        socket =
          socket
          |> assign(:running_cleanup, false)
          |> put_flash(
            :info,
            "✅ " <>
              gettext(
                "Cleanup completed successfully! Deleted %{count} old email logs (older than %{days} days).",
                count: deleted_count,
                days: retention_days
              )
          )

        {:noreply, socket}

      nil ->
        socket =
          socket
          |> assign(:running_cleanup, false)
          |> put_flash(
            :error,
            "⚠️ " <>
              gettext(
                "Cleanup operation timed out. Please try again or run it manually via mix task."
              )
          )

        {:noreply, socket}

      _error ->
        socket =
          socket
          |> assign(:running_cleanup, false)
          |> put_flash(
            :error,
            "❌ " <> gettext("Failed to run cleanup. Please check logs for details.")
          )

        {:noreply, socket}
    end
  end

  def handle_event("run_compression_now", _params, socket) do
    socket = assign(socket, :running_compression, true)

    compress_days = socket.assigns.email_compress_body

    task = Task.async(fn -> Emails.compress_old_bodies(compress_days) end)

    case Task.yield(task, 60_000) || Task.shutdown(task) do
      {:ok, {compressed_count, bytes_saved}} ->
        compression_message =
          if is_number(bytes_saved) do
            size_mb = Float.round(bytes_saved / 1024 / 1024, 2)

            "✅ " <>
              gettext(
                "Compression completed! Compressed %{count} email bodies, saved ~%{size} MB of storage.",
                count: compressed_count,
                size: size_mb
              )
          else
            "✅ " <>
              gettext(
                "Compression completed! Compressed %{count} email bodies and freed up storage space.",
                count: compressed_count
              )
          end

        socket =
          socket
          |> assign(:running_compression, false)
          |> put_flash(:info, compression_message)

        {:noreply, socket}

      nil ->
        socket =
          socket
          |> assign(:running_compression, false)
          |> put_flash(
            :error,
            "⚠️ " <>
              gettext(
                "Compression operation timed out. Please try again or run it manually via mix task."
              )
          )

        {:noreply, socket}

      _error ->
        socket =
          socket
          |> assign(:running_compression, false)
          |> put_flash(
            :error,
            "❌ " <> gettext("Failed to run compression. Please check logs for details.")
          )

        {:noreply, socket}
    end
  end

  def handle_event("toggle_s3_archival", _params, socket) do
    new_value = !socket.assigns.email_archive_to_s3

    case Emails.set_s3_archival(new_value) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_archive_to_s3, new_value)
          |> refresh_status()
          |> put_flash(
            :info,
            if(new_value,
              do: gettext("S3 archival enabled"),
              else: gettext("S3 archival disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update S3 archival"))}
    end
  end

  def handle_event("update_s3_bucket", params, socket) do
    # `phx-blur` sends the element's value under "value", not under its name —
    # reading only "s3_bucket" got `nil` on every blur and cleared the setting
    # the operator had just typed. The three fields above this one already read
    # both keys; this one has to as well. A non-string (crafted) payload is
    # refused like a failed write rather than read as blank, which would clear
    # the stored bucket.
    with bucket when is_binary(bucket) <-
           Map.get(params, "s3_bucket") || Map.get(params, "value") || "",
         bucket = String.trim(bucket),
         {:ok, _} <- Emails.set_s3_bucket(bucket) do
      socket =
        socket
        |> assign(:email_s3_bucket, bucket)
        |> put_flash(
          :info,
          if(bucket == "",
            do: gettext("S3 bucket cleared"),
            else: gettext("S3 bucket set to %{bucket}", bucket: bucket)
          )
        )

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Failed to update S3 bucket"))}
    end
  end

  def handle_event("update_s3_integration", params, socket) do
    # Same shape problem: a `phx-change` on a <select> outside a form sends
    # `%{"value" => uuid}`. Same refusal of a non-string payload, too.
    with uuid when is_binary(uuid) <-
           Map.get(params, "s3_integration") || Map.get(params, "value") || "",
         {:ok, _} <- Emails.set_s3_integration(uuid) do
      socket =
        socket
        |> assign(:email_s3_integration, uuid)
        |> put_flash(
          :info,
          if(uuid == "",
            do: gettext("Archive uploads will use the ambient AWS credentials"),
            else: gettext("Archive uploads will use the selected connection")
          )
        )

      {:noreply, socket}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update the archive connection"))}
    end
  end

  # Every eligible connection, not only the ones a SendProfile points at: an
  # operator can reasonably keep archival on an account that sends no mail at
  # all, and `AwsIntegrations.active_integrations_with_names/0` would hide it.
  #
  # Both `aws_ses` (an install may already have pointed archival at an SES
  # connection, before `object_storage` existed — `Archiver.s3_request_config/0`
  # still honors it) and `object_storage` (the type built for this) — matching
  # what `Emails.s3_archival_credentials/1` actually accepts. Two providers
  # can produce same-named connections ("Production" for both a mailbox and a
  # bucket is a plausible operator choice), so each option is labelled with
  # its provider, not just its name.
  defp s3_connections do
    ["aws_ses", "object_storage"]
    |> PhoenixKit.Integrations.load_all_connections()
    |> Enum.flat_map(fn {provider, connections} ->
      Enum.map(connections, fn %{uuid: uuid} = conn ->
        label = "#{Map.get(conn, :name) || uuid} (#{provider_display_name(provider)})"
        {uuid, label}
      end)
    end)
    |> Enum.sort_by(fn {_uuid, label} -> String.downcase(label) end)
  rescue
    _ -> []
  end

  # Falls back to the raw key when core doesn't recognize it — this package's
  # own hex-pinned core floor predates `object_storage`, so `Providers.get/1`
  # returns nil there even though the provider key itself works fine end to
  # end (see the `object_storage_config/1` duplication note in archiver.ex).
  defp provider_display_name(key) do
    case Providers.get(key) do
      %{name: name} -> name
      _ -> key
    end
  end
end
