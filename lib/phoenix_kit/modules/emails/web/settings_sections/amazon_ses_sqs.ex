defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs do
  @moduledoc """
  "Amazon SES & SQS" section on the core Email Sending settings page
  (`/admin/settings/email-sending`).

  Covers the module's SES-specific concerns: which Integrations connection
  (or legacy manual credentials) supplies SES/SQS credentials, event
  tracking, one-click infrastructure setup, and the SQS polling worker.
  Contributed via `PhoenixKit.Modules.Emails.email_settings_sections/0`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  import PhoenixKitWeb.Components.Core.AWSCredentialsVerify

  alias PhoenixKit.AWS.CredentialsVerifier
  alias PhoenixKit.AWS.InfrastructureSetup
  alias PhoenixKit.Config.AWS
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Live.Components.SearchableSelect

  @dialyzer {:nowarn_function, handle_event: 3}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.has_key?(socket.assigns, :aws_settings) do
        socket
      else
        email_config = Emails.get_config()

        aws_settings = %{
          access_key_id: Settings.get_setting("aws_access_key_id", ""),
          secret_access_key: Settings.get_setting("aws_secret_access_key", ""),
          region: Settings.get_setting("aws_region", ""),
          sqs_queue_url: Settings.get_setting("aws_sqs_queue_url", ""),
          sqs_dlq_url: Settings.get_setting("aws_sqs_dlq_url", ""),
          sqs_queue_arn: Settings.get_setting("aws_sqs_queue_arn", ""),
          sns_topic_arn: Settings.get_setting("aws_sns_topic_arn", ""),
          ses_configuration_set: Settings.get_setting("aws_ses_configuration_set", ""),
          sqs_polling_interval_ms: Settings.get_setting("sqs_polling_interval_ms", "5000")
        }

        socket
        |> assign(:mailer_status, Utils.mailer_adapter_status())
        |> assign(:current_provider, Emails.current_provider())
        |> assign(:aws_configured, Emails.aws_configured?())
        |> assign(:email_ses_events, email_config.ses_events)
        |> assign(:sqs_polling_enabled, email_config.sqs_polling_enabled)
        |> assign(:sqs_max_messages_per_poll, email_config.sqs_max_messages_per_poll)
        |> assign(:sqs_visibility_timeout, email_config.sqs_visibility_timeout)
        |> assign(:aws_settings, aws_settings)
        |> assign(:aws_ses_connections, Integrations.list_connections("aws_ses"))
        |> assign(
          :selected_aws_integration_uuid,
          Settings.get_setting("emails_aws_integration_uuid", "")
        )
        |> assign(:saving, false)
        |> assign(:setting_up_aws, false)
        |> assign(:verifying_credentials, false)
        |> assign(:credential_verification_status, :pending)
        |> assign(:credential_verification_message, "")
        |> assign(:aws_permissions, %{})
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_email_ses_events", _params, socket) do
    new_ses_events = !socket.assigns.email_ses_events

    case Emails.set_ses_events(new_ses_events) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_ses_events, new_ses_events)
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

  def handle_event("toggle_sqs_polling", _params, socket) do
    # Route through SQSPollingManager so the poller starts/stops at RUNTIME
    # with no app restart: enable_polling/0 persists the flag AND inserts
    # the first Oban polling job (which self-schedules the next);
    # disable_polling/0 clears the flag AND cancels scheduled jobs.
    new_sqs_polling = !socket.assigns.sqs_polling_enabled

    result =
      if new_sqs_polling do
        SQSPollingManager.enable_polling()
      else
        SQSPollingManager.disable_polling()
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
        |> assign(:sqs_polling_enabled, new_sqs_polling)
        |> put_flash(
          :info,
          if(new_sqs_polling,
            do: gettext("SQS polling enabled"),
            else: gettext("SQS polling disabled")
          )
        )

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, gettext("Failed to update SQS polling setting"))}
    end
  end

  def handle_event("update_max_messages", params, socket) do
    value = Map.get(params, "max_messages") || Map.get(params, "value")

    case Integer.parse(value) do
      {max_messages, _} when max_messages >= 1 and max_messages <= 10 ->
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

    case Integer.parse(value) do
      {timeout, _} when timeout >= 30 and timeout <= 43_200 ->
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

  def handle_event("setup_aws_infrastructure", _params, socket) do
    socket = assign(socket, :setting_up_aws, true)

    project_name =
      Settings.get_setting("project_title", "myapp")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim("-")

    aws_config = socket.assigns.aws_settings
    region = aws_config.region || AWS.region()

    access_key_id =
      if aws_config.access_key_id != "", do: aws_config.access_key_id, else: nil

    secret_access_key =
      if aws_config.secret_access_key != "", do: aws_config.secret_access_key, else: nil

    if access_key_id && secret_access_key do
      case InfrastructureSetup.run(
             project_name: project_name,
             region: region,
             access_key_id: access_key_id,
             secret_access_key: secret_access_key
           ) do
        {:ok, config} ->
          case Settings.update_settings_batch(config) do
            {:ok, _results} ->
              new_aws_settings = %{
                access_key_id: access_key_id,
                secret_access_key: secret_access_key,
                region: config["aws_region"],
                sqs_queue_url: config["aws_sqs_queue_url"],
                sqs_dlq_url: config["aws_sqs_dlq_url"],
                sqs_queue_arn: config["aws_sqs_queue_arn"],
                sns_topic_arn: config["aws_sns_topic_arn"],
                ses_configuration_set: config["aws_ses_configuration_set"],
                sqs_polling_interval_ms: config["sqs_polling_interval_ms"]
              }

              socket =
                socket
                |> assign(:aws_settings, new_aws_settings)
                |> assign(:setting_up_aws, false)
                |> put_flash(:info, """
                ✅ AWS Email Infrastructure Created Successfully!

                📦 Created Resources:
                • Project: #{project_name}
                • Region: #{config["aws_region"]}
                • SNS Topic: #{config["aws_sns_topic_arn"]}
                • SQS Queue: #{config["aws_sqs_queue_url"]}
                • Dead Letter Queue: #{config["aws_sqs_dlq_url"]}
                • SES Configuration Set: #{config["aws_ses_configuration_set"]}

                🎉 All settings have been automatically filled below.
                Click "Save AWS Settings" to persist the configuration.

                ⚡ Next steps:
                1. Verify your email/domain in AWS SES Console
                2. Enable SQS Polling below
                3. Start sending emails!
                """)

              {:noreply, socket}

            {:error, _failed_operation, _failed_value, _changes} ->
              socket =
                socket
                |> assign(:setting_up_aws, false)
                |> put_flash(:error, """
                ⚠️ Infrastructure created but failed to save settings.

                AWS resources were created successfully, but there was an error saving configuration to database.
                Please save AWS settings manually.
                """)

              {:noreply, socket}
          end

        {:error, step, reason} ->
          socket =
            socket
            |> assign(:setting_up_aws, false)
            |> put_flash(:error, """
            ❌ AWS Setup Failed

            Failed at step: #{step}
            Reason: #{reason}

            Please check:
            • AWS credentials are valid
            • IAM permissions (SQS, SNS, SES, STS)
            • AWS region is correct
            • No resource limits exceeded

            You can also use the manual bash script:
            ./scripts/setup_aws_email_infrastructure.sh
            """)

          {:noreply, socket}
      end
    else
      socket =
        socket
        |> assign(:setting_up_aws, false)
        |> put_flash(:error, """
        ❌ AWS Credentials Required

        Please configure AWS Access Key ID and Secret Access Key before running setup.

        You can get these credentials from AWS IAM Console:
        https://console.aws.amazon.com/iam/home#/users
        """)

      {:noreply, socket}
    end
  end

  def handle_event("save_aws_settings", %{"aws_settings" => aws_params}, socket) do
    socket = assign(socket, :saving, true)

    settings_to_update = %{
      "aws_access_key_id" => String.trim(aws_params["access_key_id"] || ""),
      "aws_secret_access_key" => String.trim(aws_params["secret_access_key"] || ""),
      "aws_region" =>
        if(aws_params["region"] in [nil, ""],
          do: AWS.region(),
          else: aws_params["region"]
        ),
      "aws_sqs_queue_url" => aws_params["sqs_queue_url"] || "",
      "aws_sqs_dlq_url" => aws_params["sqs_dlq_url"] || "",
      "aws_sqs_queue_arn" => aws_params["sqs_queue_arn"] || "",
      "aws_sns_topic_arn" => aws_params["sns_topic_arn"] || "",
      "aws_ses_configuration_set" =>
        if(aws_params["ses_configuration_set"] in [nil, ""],
          do: "phoenixkit-tracking",
          else: aws_params["ses_configuration_set"]
        ),
      "sqs_polling_interval_ms" =>
        if(aws_params["sqs_polling_interval_ms"] in [nil, ""],
          do: "5000",
          else: aws_params["sqs_polling_interval_ms"]
        )
    }

    case Settings.update_settings_batch(settings_to_update) do
      {:ok, _results} ->
        new_aws_settings = build_aws_settings_map(aws_params)

        socket =
          socket
          |> assign(:aws_settings, new_aws_settings)
          |> assign(:saving, false)
          |> put_flash(:info, gettext("AWS settings saved successfully"))

        {:noreply, socket}

      {:error, _failed_operation, _failed_value, _changes} ->
        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, gettext("Failed to save AWS settings"))

        {:noreply, socket}
    end
  end

  def handle_event("select_aws_integration", %{"uuid" => uuid}, socket) do
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

        socket =
          socket
          |> assign(:selected_aws_integration_uuid, uuid)
          |> put_flash(:info, gettext("SES credentials source updated"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update SES credentials source"))}
    end
  end

  def handle_event("verify_aws_credentials", _params, socket) do
    aws_settings = socket.assigns.aws_settings

    if credentials_missing?(aws_settings) do
      {:noreply,
       assign_verification_error(
         socket,
         "Please enter Access Key ID and Secret Access Key before verification."
       )}
    else
      socket = assign(socket, :verifying_credentials, true)

      task = Task.async(fn -> verify_aws_credentials(aws_settings) end)

      case Task.yield(task, 15_000) || Task.shutdown(task) do
        {:ok, result} ->
          {:noreply, handle_verification_result(socket, result)}

        nil ->
          {:noreply,
           assign_verification_error(socket, "❌ Verification timed out. Please try again.")}
      end
    end
  end

  # Private helpers for AWS credentials verification

  defp credentials_missing?(aws_settings) do
    String.trim(aws_settings.access_key_id) == "" or
      String.trim(aws_settings.secret_access_key) == ""
  end

  defp verify_aws_credentials(aws_settings) do
    CredentialsVerifier.verify_credentials(
      aws_settings.access_key_id,
      aws_settings.secret_access_key,
      aws_settings.region
    )
  end

  defp assign_verification_error(socket, message) do
    socket
    |> assign(:verifying_credentials, false)
    |> assign(:credential_verification_status, :error)
    |> assign(:credential_verification_message, message)
  end

  defp handle_verification_result(socket, {:ok, credential_info}) do
    socket
    |> assign(:verifying_credentials, false)
    |> assign(:credential_verification_status, :success)
    |> assign(
      :credential_verification_message,
      "✅ Credentials verified! Account: #{credential_info.account_id}. Ready for Setup AWS Infrastructure."
    )
    |> assign(:aws_permissions, %{})
  end

  defp handle_verification_result(socket, {:error, :invalid_credentials, message}) do
    assign_verification_error(socket, "❌ Invalid credentials: #{message}")
  end

  defp handle_verification_result(socket, {:error, :authentication_failed, message}) do
    assign_verification_error(socket, "❌ Authentication failed: #{message}")
  end

  defp handle_verification_result(socket, {:error, :configuration_error, message}) do
    assign_verification_error(socket, "❌ Configuration error: #{message}")
  end

  defp handle_verification_result(socket, {:error, :rate_limited, message}) do
    assign_verification_error(socket, "❌ Rate limited: #{message}")
  end

  defp handle_verification_result(socket, {:error, :network_error, message}) do
    assign_verification_error(socket, "❌ Network error: #{message}")
  end

  defp handle_verification_result(socket, {:error, :response_error, message}) do
    assign_verification_error(socket, "❌ Response parsing error: #{message}")
  end

  defp handle_verification_result(socket, {:error, reason}) do
    assign_verification_error(socket, "❌ Verification failed: #{reason}")
  end

  # Paste-able config.exs snippet to configure (or switch to) the Amazon SES
  # adapter, using the actually-detected mailer module/app so it's always
  # copy-pasteable as-is.
  defp mailer_config_snippet(%{config_app: app, config_module: mod}) do
    """
    config :#{app}, #{inspect(mod)},
      adapter: Swoosh.Adapters.AmazonSES,
      region: "eu-north-1"
    """
  end

  defp build_aws_settings_map(aws_params) do
    %{
      access_key_id: aws_params["access_key_id"] || "",
      secret_access_key: aws_params["secret_access_key"] || "",
      region: aws_params["region"] || "",
      sqs_queue_url: aws_params["sqs_queue_url"] || "",
      sqs_dlq_url: aws_params["sqs_dlq_url"] || "",
      sqs_queue_arn: aws_params["sqs_queue_arn"] || "",
      sns_topic_arn: aws_params["sns_topic_arn"] || "",
      ses_configuration_set: aws_params["ses_configuration_set"] || "",
      sqs_polling_interval_ms: aws_params["sqs_polling_interval_ms"] || "5000"
    }
  end
end
