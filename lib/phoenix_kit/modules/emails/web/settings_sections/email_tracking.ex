defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking do
  @moduledoc """
  "Email Tracking" section on the core Email Sending settings page
  (`/admin/settings/email-sending`).

  Covers what to store for each outgoing email (body, headers, sampling
  rate) and how long to keep it (retention, compression, S3 archival).
  Contributed via `PhoenixKit.Modules.Emails.email_settings_sections/0`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Modules.Emails

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

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
        |> assign(:running_cleanup, false)
        |> assign(:running_compression, false)
        |> assign(:running_archival, false)
        |> assign(:updating_compress_days, false)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_email_save_body", _params, socket) do
    new_save_body = !socket.assigns.email_save_body

    case Emails.set_save_body(new_save_body) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_body, new_save_body)
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

  def handle_event("toggle_email_save_headers", _params, socket) do
    new_save_headers = !socket.assigns.email_save_headers

    case Emails.set_save_headers(new_save_headers) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_headers, new_save_headers)
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

    case Integer.parse(value) do
      {sampling_rate, _} when sampling_rate >= 0 and sampling_rate <= 100 ->
        case Emails.set_sampling_rate(sampling_rate) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_sampling_rate, sampling_rate)
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

    case Integer.parse(value) do
      {retention_days, _} when retention_days > 0 and retention_days <= 365 ->
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

    case Integer.parse(value) do
      {compress_days, _} when compress_days >= 7 and compress_days <= 365 ->
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

  def handle_event("toggle_s3_archival", _params, socket) do
    new_s3_archival = !socket.assigns.email_archive_to_s3

    case Emails.set_s3_archival(new_s3_archival) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_archive_to_s3, new_s3_archival)
          |> put_flash(
            :info,
            if(new_s3_archival,
              do: gettext("S3 archival enabled"),
              else: gettext("S3 archival disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update S3 archival setting"))
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

  def handle_event("run_s3_archival_now", _params, socket) do
    if socket.assigns.email_archive_to_s3 do
      socket = assign(socket, :running_archival, true)

      retention_days = socket.assigns.email_retention_days

      task = Task.async(fn -> Emails.archive_to_s3(retention_days) end)

      case Task.yield(task, 120_000) || Task.shutdown(task) do
        {:ok, {:ok, archived_count: count}} ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :info,
              "✅ " <>
                gettext(
                  "S3 archival completed successfully! Archived %{count} email logs to S3.",
                  count: count
                )
            )

          {:noreply, socket}

        {:ok, {:ok, :skipped}} ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(:info, "ℹ️ " <> gettext("No emails to archive at this time."))

          {:noreply, socket}

        {:ok, {:error, :s3_not_configured}} ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :error,
              "❌ " <>
                gettext("S3 is not configured. Please configure AWS S3 bucket settings first.")
            )

          {:noreply, socket}

        {:ok, {:error, :no_bucket_configured}} ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :error,
              "❌ " <> gettext("S3 bucket not configured. Please set 'email_s3_bucket' setting.")
            )

          {:noreply, socket}

        {:ok, {:error, reason}} ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :error,
              "❌ " <> gettext("S3 archival failed: %{reason}", reason: inspect(reason))
            )

          {:noreply, socket}

        nil ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :error,
              "⚠️ " <>
                gettext(
                  "S3 archival timed out. Large archives may take longer. Check logs for progress."
                )
            )

          {:noreply, socket}

        _error ->
          socket =
            socket
            |> assign(:running_archival, false)
            |> put_flash(
              :error,
              "❌ " <> gettext("Failed to run S3 archival. Please check logs for details.")
            )

          {:noreply, socket}
      end
    else
      socket =
        put_flash(
          socket,
          :error,
          "❌ " <> gettext("S3 archival is disabled. Please enable it first.")
        )

      {:noreply, socket}
    end
  end
end
