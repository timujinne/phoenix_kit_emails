defmodule PhoenixKit.Modules.Emails do
  @moduledoc """
  Email system for PhoenixKit - main API module.

  This module provides the primary interface for email functionality,
  including system configuration, log management, event management, and analytics.

  ## Core Features

  - **Email Logging**: Comprehensive logging of all outgoing emails
  - **Event Management**: Manage delivery, bounce, complaint, open, and click events
  - **AWS SES Integration**: Deep integration with AWS SES for event management
  - **Analytics**: Detailed metrics and engagement analysis
  - **System Settings**: Configurable options for system behavior
  - **Rate Limiting**: Protection against abuse and spam
  - **Archival**: Automatic cleanup and archival of old data

  ## System Settings

  All settings are stored in the PhoenixKit settings system with module "email_system":

  - `email_enabled` - Enable/disable the entire system
  - `email_save_body` - Save full email body (vs preview only)
  - `email_save_headers` - Save email headers (vs empty map)
  - `email_ses_events` - Manage AWS SES delivery events
  - `email_retention_days` - Days to keep emails (default: 90)
  - `aws_ses_configuration_set` - AWS SES configuration set name
  - `email_compress_body` - Compress body after N days
  - `email_archive_to_s3` - Enable S3 archival
  - `email_s3_bucket` - S3 bucket archives are written to
  - `email_s3_integration` - Integrations connection that signs uploads (unset = ExAws chain)
  - `email_sampling_rate` - Percentage of emails to fully log
  - `email_create_placeholder_logs` - Create placeholder logs for orphaned events (default: false)

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if email system is enabled
  - `enable_system/0` - Enable email system
  - `disable_system/0` - Disable email system
  - `get_config/0` - Get current system configuration
  - `placeholder_logs_enabled?/0` - Check if placeholder log creation is enabled
  - `set_placeholder_logs/1` - Enable/disable placeholder log creation

  ### Email Log Management
  - `list_logs/1` - Get emails with filters
  - `get_log!/1` - Get email log by ID
  - `create_log/1` - Create new email log
  - `update_log_status/2` - Update log status

  ### Event Management
  - `create_event/1` - Create system event
  - `list_events_for_log/1` - Get events for specific log
  - `process_webhook_event/1` - Process incoming webhook

  ### Analytics & Metrics
  - `get_system_stats/1` - Overall system statistics
  - `get_engagement_metrics/1` - Open/click rate analysis
  - `get_campaign_stats/1` - Campaign-specific metrics
  - `get_provider_performance/1` - Provider comparison

  ### Maintenance
  - `cleanup_old_logs/1` - Remove old logs
  - `compress_old_bodies/1` - Compress storage
  - `archive_to_s3/1` - Archive to S3

  ## Usage Examples

      # Check if system is enabled
      if PhoenixKit.Modules.Emails.enabled?() do
        # System is active
      end

      # Get system statistics
      stats = PhoenixKit.Modules.Emails.get_system_stats(:last_30_days)
      # => %{total_sent: 5000, delivered: 4850, bounce_rate: 2.5, open_rate: 23.4}

      # Get campaign performance
      campaign_stats = PhoenixKit.Modules.Emails.get_campaign_stats("newsletter_2024")
      # => %{total_sent: 1000, delivery_rate: 98.5, open_rate: 25.2, click_rate: 4.8}

      # Process webhook from AWS SES
      {:ok, event} = PhoenixKit.Modules.Emails.process_webhook_event(webhook_data)

      # Clean up old data
      {deleted_count, _} = PhoenixKit.Modules.Emails.cleanup_old_logs(90)

  ## Configuration Example

      # In your application config
      config :phoenix_kit,
        email_enabled: true,
        email_save_body: false,
        email_retention_days: 90,
        aws_ses_configuration_set: "my-app-system"
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Config.AWS
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Integrations

  alias PhoenixKit.Modules.Emails.{
    Archiver,
    AwsIntegrations,
    Event,
    Log,
    SQSPollingJob,
    SQSProcessor,
    Utils
  }

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  import Ecto.Query, only: [where: 3, group_by: 3, select: 3]

  require Logger

  # See aws_ses_credentials/0's comment for why this exists.
  @aws_credentials_cache_name :emails_aws_credentials
  @aws_credentials_cache_ttl_ms 60_000

  @doc """
  PubSub topic on which email log status changes are broadcast.

  Subscribed to by admin LiveViews (e.g. the emails list) and broadcast from
  `PhoenixKit.Modules.Emails.Log.update_log/2` whenever a log's status changes.
  Single source of truth for both the broadcaster and the subscribers.
  """
  def email_status_topic, do: "phoenix_kit_emails:status"

  ## --- Manual Synchronization Functions ---

  # Check if message ID matches AWS SES format
  defp aws_message_id?(message_id) do
    String.match?(
      message_id,
      ~r/^[0-9a-f]{16}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9]{6}$/
    )
  end

  # Check if message ID is PhoenixKit internal format
  defp internal_message_id?(message_id) do
    String.starts_with?(message_id, "pk_")
  end

  # Find log and prepare result tuple
  defp find_log_and_prepare_result(message_id, search_type, log_finder_fn) do
    case log_finder_fn.(message_id) do
      {:ok, log} ->
        aws_id =
          if search_type == :aws_message_id,
            do: message_id,
            else: log.aws_message_id || message_id

        log_message(search_type, true, log, message_id, aws_id)
        {log, aws_id, search_type}

      {:error, :not_found} ->
        log_message(search_type, false, nil, message_id, message_id)
        {nil, message_id, search_type}
    end
  end

  # Log search results
  defp log_message(search_type, found?, log, message_id, aws_id) do
    case {search_type, found?} do
      {:aws_message_id, true} ->
        Logger.info("Found existing email log by AWS message ID", %{
          log_uuid: log.uuid,
          current_status: log.status,
          aws_message_id: message_id
        })

      {:aws_message_id, false} ->
        Logger.info("No existing email log found for AWS message_id: #{message_id}")

      {:internal_message_id, true} ->
        Logger.info("Found existing email log by internal message ID", %{
          log_uuid: log.uuid,
          current_status: log.status,
          internal_message_id: message_id,
          aws_message_id: aws_id
        })

      {:internal_message_id, false} ->
        Logger.warning("No existing email log found for internal message_id: #{message_id}")

      {:unknown_format, true} ->
        Logger.info("Found existing email log by unknown message ID format", %{
          log_uuid: log.uuid,
          current_status: log.status,
          search_message_id: message_id,
          aws_message_id: aws_id
        })

      {:unknown_format, false} ->
        Logger.info("No existing email log found for message_id: #{message_id}")
    end
  end

  # Determine the search strategy and AWS message ID to use for SQS search
  defp determine_search_strategy(message_id) do
    cond do
      aws_message_id?(message_id) ->
        find_log_and_prepare_result(
          message_id,
          :aws_message_id,
          &Log.find_by_aws_message_id/1
        )

      internal_message_id?(message_id) ->
        find_log_and_prepare_result(message_id, :internal_message_id, &get_log_by_message_id/1)

      true ->
        handle_unknown_format_search(message_id)
    end
  end

  # Handle unknown format by trying both search approaches
  defp handle_unknown_format_search(message_id) do
    case get_log_by_message_id(message_id) do
      {:ok, log} ->
        aws_id = log.aws_message_id || message_id
        log_message(:unknown_format, true, log, message_id, aws_id)
        {log, aws_id, :unknown_format}

      {:error, :not_found} ->
        case Log.find_by_aws_message_id(message_id) do
          {:ok, log} ->
            Logger.info("Found existing email log by AWS message ID (fallback)", %{
              log_uuid: log.uuid,
              current_status: log.status,
              aws_message_id: message_id
            })

            {log, message_id, :unknown_format}

          {:error, :not_found} ->
            log_message(:unknown_format, false, nil, message_id, message_id)
            {nil, message_id, :unknown_format}
        end
    end
  end

  @doc """
  Manually sync email status by fetching events from SQS queues.

  This function searches for events in both the main SQS queue and DLQ
  that match the given message_id and processes them to update email status.

  ## Parameters

  - `message_id` - The AWS SES message ID or internal PhoenixKit message ID to sync

  ## Returns

  - `{:ok, result}` - Successful sync with processing results
  - `{:error, reason}` - Error during sync process

  ## Examples

      iex> PhoenixKit.Modules.Emails.sync_email_status("0110019971abc123-...")
      {:ok, %{events_processed: 3, log_updated: true}}

      iex> PhoenixKit.Modules.Emails.sync_email_status("pk_abc123...")
      {:ok, %{events_processed: 1, log_updated: true}}
  """
  def sync_email_status(message_id) when is_binary(message_id) do
    Logger.info("Starting email status sync", %{message_id: message_id})

    if enabled?() do
      # Check AWS configuration first
      if aws_configured?() do
        try do
          # Determine the search strategy based on message ID type
          {existing_log, aws_message_id, search_strategy} = determine_search_strategy(message_id)

          # Get events from SQS and DLQ using the appropriate message ID
          Logger.debug("Fetching events from SQS and DLQ queues", %{
            search_strategy: search_strategy,
            aws_message_id: aws_message_id,
            original_message_id: message_id
          })

          # The log knows which account sent it (when the send path could tell);
          # searching only that account's queue is both faster and honest.
          search_opts =
            case existing_log do
              %{integration_uuid: uuid} when is_binary(uuid) and uuid != "" ->
                [integration_uuid: uuid]

              _ ->
                []
            end

          sqs_events = fetch_sqs_events_for_message(aws_message_id, search_opts)
          dlq_events = fetch_dlq_events_for_message(aws_message_id, search_opts)

          # Deduplicate events from both queues by message ID + event type
          all_events =
            (sqs_events ++ dlq_events)
            |> Enum.uniq_by(fn event ->
              {get_in(event, ["mail", "messageId"]), event["eventType"]}
            end)

          Logger.info("Event search results", %{
            message_id: message_id,
            sqs_events: length(sqs_events),
            dlq_events: length(dlq_events),
            total_events: length(all_events)
          })

          if Enum.empty?(all_events) do
            message =
              if existing_log do
                "No new events found in SQS/DLQ for this email"
              else
                "No events found and no email log exists for this message ID"
              end

            {:ok,
             %{
               events_processed: 0,
               total_events_found: 0,
               sqs_events_found: 0,
               dlq_events_found: 0,
               log_updated: false,
               existing_log_found: existing_log != nil,
               message: message
             }}
          else
            # Process events through SQS processor
            results =
              Enum.with_index(all_events, 1)
              |> Enum.map(fn {event, index} ->
                result = SQSProcessor.process_email_event(event)

                case result do
                  {:ok, _} ->
                    result

                  {:error, reason} ->
                    Logger.warning("Failed to process event #{index}: #{inspect(reason)}")
                    result
                end
              end)

            successful_results =
              Enum.filter(results, fn
                {:ok, _} -> true
                _ -> false
              end)

            failed_results =
              Enum.filter(results, fn
                {:error, _} -> true
                _ -> false
              end)

            Logger.info("Event processing completed", %{
              message_id: message_id,
              total_events: length(all_events),
              successful: length(successful_results),
              failed: length(failed_results)
            })

            {:ok,
             %{
               events_processed: length(successful_results),
               events_failed: length(failed_results),
               total_events_found: length(all_events),
               sqs_events_found: length(sqs_events),
               dlq_events_found: length(dlq_events),
               log_updated: not Enum.empty?(successful_results),
               existing_log_found: existing_log != nil,
               results: successful_results,
               failed_results: failed_results,
               message:
                 "Successfully processed #{length(successful_results)}/#{length(all_events)} events"
             }}
          end
        rescue
          error ->
            Logger.error("Error during email status sync", %{
              message_id: message_id,
              error: inspect(error),
              stacktrace: Exception.format_stacktrace(__STACKTRACE__)
            })

            {:error, "Failed to sync email status: #{Exception.message(error)}"}
        end
      else
        {:error,
         "AWS credentials not configured. Configure via Web UI at /admin/settings/email-sending or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."}
      end
    else
      {:error, "Email system is disabled. Please enable it in settings."}
    end
  end

  @doc """
  Fetch SES events from main SQS queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID.
  Account-aware: see `search_targets/1`. A message whose log carries an
  `integration_uuid` is looked for in THAT account's queue; otherwise every
  configured account is searched.

  """
  def fetch_sqs_events_for_message(message_id, opts \\ []) do
    opts
    |> search_targets()
    |> Enum.flat_map(fn %{queue_url: queue_url, aws_config: aws_config} ->
      fetch_sqs_events_from(message_id, queue_url, aws_config)
    end)
  end

  @doc false
  # Which queues a "sync now" should look in, as
  # `%{queue_url: ..., aws_config: ...}`.
  #
  # `:integration_uuid` (taken from the message's own log, when it has one)
  # narrows the search to that account. Without it every configured account is
  # searched, because the alternative — the global queue only — silently
  # returns nothing for a message sent through any other account, and "no
  # events found" is indistinguishable from "looked in the wrong place".
  #
  # Reuses `SQSPollingJob`'s own account resolution rather than re-deriving it:
  # the legacy single-queue deployment appears there as an account with no
  # uuid, so this covers it without a special case, and a queue that the poller
  # would not touch is not one this should be reaching into either.
  @spec search_targets(keyword()) :: [%{queue_url: String.t(), aws_config: keyword()}]
  def search_targets(opts \\ []) do
    requested = Keyword.get(opts, :integration_uuid)

    SQSPollingJob.configured_accounts()
    |> filter_search_accounts(requested)
    |> Enum.flat_map(fn account ->
      case SQSPollingJob.resolve_aws_config(account) do
        {:ok, aws_config} ->
          [%{queue_url: account.queue_url, aws_config: aws_config}]

        {:error, reason} ->
          Logger.warning("Skipping account in event search: credentials unresolved", %{
            integration_uuid: account.integration_uuid,
            reason: inspect(reason)
          })

          []
      end
    end)
  end

  # An account the log names but that has no queue configured leaves nothing to
  # search — falling back to "search everything" there would be worse than
  # returning nothing, because it would report another account's events as this
  # message's.
  defp filter_search_accounts(accounts, uuid) when is_binary(uuid) and uuid != "" do
    Enum.filter(accounts, &(&1.integration_uuid == uuid))
  end

  defp filter_search_accounts(accounts, _uuid), do: accounts

  defp fetch_sqs_events_from(message_id, queue_url, aws_config) do
    cond do
      not aws_configured?() ->
        []

      is_nil(queue_url) or queue_url == "" ->
        Logger.warning("SQS queue URL not configured", %{
          setting: "aws_sqs_queue_url",
          current_value: queue_url
        })

        []

      not valid_queue_url?(queue_url) ->
        Logger.error("Invalid SQS queue URL format", %{
          queue_url: queue_url,
          expected_format: "https://sqs.{region}.amazonaws.com/{account_id}/{queue_name}"
        })

        []

      true ->
        try do
          Logger.info("Starting SQS message search", %{
            message_id: message_id,
            queue_url: queue_url
          })

          # Poll multiple batches to find the target message
          found_events = poll_sqs_for_message(queue_url, aws_config, message_id, [], 0, 5)

          Logger.info("SQS search completed", %{
            message_id: message_id,
            queue_url: queue_url,
            events_found: length(found_events)
          })

          found_events
        rescue
          error ->
            Logger.error("Failed to fetch SQS events", %{
              error: inspect(error),
              message_id: message_id,
              queue_url: queue_url
            })

            []
        end
    end
  end

  @doc """
  Fetch SES events from DLQ queue for specific message ID.

  ## Parameters

  - `message_id` - The AWS SES message ID to search for

  ## Returns

  List of SES events matching the message ID from DLQ.
  Account-aware: see `search_targets/1`. A message whose log carries an
  `integration_uuid` is looked for in THAT account's queue; otherwise every
  configured account is searched.

  """
  def fetch_dlq_events_for_message(message_id, opts \\ []) do
    opts
    |> dlq_search_targets()
    |> Enum.flat_map(fn {dlq_url, aws_config} ->
      fetch_dlq_events_from(message_id, dlq_url, aws_config)
    end)
  end

  # The DLQ URL lives in the same per-account tracking row as the queue URL, so
  # the account set is the poller's; only the URL differs. The legacy account
  # (no uuid) still reads the global setting.
  defp dlq_search_targets(opts) do
    requested = Keyword.get(opts, :integration_uuid)

    SQSPollingJob.configured_accounts()
    |> filter_search_accounts(requested)
    |> Enum.flat_map(fn account ->
      dlq_url = account_dlq_url(account)

      with true <- is_binary(dlq_url) and dlq_url != "",
           {:ok, aws_config} <- SQSPollingJob.resolve_aws_config(account) do
        [{dlq_url, aws_config}]
      else
        _ -> []
      end
    end)
  end

  defp account_dlq_url(%{integration_uuid: uuid}) when is_binary(uuid) do
    case get_aws_tracking(uuid) do
      %{dlq_url: dlq_url} when is_binary(dlq_url) and dlq_url != "" -> dlq_url
      _ -> Settings.get_setting("aws_sqs_dlq_url")
    end
  end

  defp account_dlq_url(_account), do: Settings.get_setting("aws_sqs_dlq_url")

  defp fetch_dlq_events_from(message_id, dlq_url, aws_config) do
    if dlq_url && aws_configured?() do
      try do
        # Poll multiple batches to find the target message (don't delete from DLQ)
        found_events = poll_dlq_for_message(dlq_url, message_id, [], 0, 5, aws_config)

        Logger.info("DLQ search completed", %{
          message_id: message_id,
          events_found: length(found_events)
        })

        found_events
      rescue
        error ->
          Logger.warning("Failed to fetch DLQ events: #{inspect(error)}")
          []
      end
    else
      []
    end
  end

  # Helper function to check message_id in message
  defp parse_and_check_message_id(sqs_message, target_message_id) do
    case SQSProcessor.parse_sns_message(sqs_message) do
      {:ok, event_data} ->
        message_id = get_in(event_data, ["mail", "messageId"])
        message_id == target_message_id

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

  # Helper function to poll SQS in batches to find specific message
  defp poll_sqs_for_message(
         queue_url,
         aws_config,
         target_message_id,
         found_events,
         batch_count,
         max_batches
       ) do
    if batch_count >= max_batches do
      found_events
    else
      # Poll for messages with visibility timeout
      # Use system settings for configuration
      max_messages = get_sqs_max_messages()
      visibility_timeout = get_sqs_visibility_timeout()

      messages =
        ExAws.SQS.receive_message(queue_url,
          max_number_of_messages: max_messages,
          visibility_timeout: visibility_timeout,
          wait_time_seconds: 2
        )
        |> ExAws.request(aws_config)
        |> case do
          {:ok, %{"Messages" => messages}} when is_list(messages) ->
            messages

          {:ok, %{"messages" => messages}} when is_list(messages) ->
            messages

          {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
            messages

          {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
            messages

          {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
            messages

          {:ok, _response} ->
            []

          {:error, {:http_error, status_code, %{code: error_code, message: error_message}}} ->
            Logger.error("SQS HTTP error", %{
              status_code: status_code,
              error_code: error_code,
              error_message: error_message,
              queue_url: queue_url,
              region: aws_config[:region]
            })

            []

          error ->
            Logger.warning("SQS poll error", %{
              error: inspect(error),
              queue_url: queue_url,
              region: aws_config[:region]
            })

            []
        end

      if Enum.empty?(messages) do
        # No more messages, stop polling
        found_events
      else
        # Process this batch
        {matching_messages, messages_to_delete} =
          process_sqs_batch(messages, target_message_id)

        # Delete processed messages from queue
        delete_sqs_messages(queue_url, aws_config, messages_to_delete)

        new_found_events = found_events ++ matching_messages

        if Enum.empty?(matching_messages) do
          # No matches in this batch, continue to next batch
          poll_sqs_for_message(
            queue_url,
            aws_config,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches
          )
        else
          # Found matches, return immediately
          new_found_events
        end
      end
    end
  end

  # Process a batch of SQS messages
  defp process_sqs_batch(messages, target_message_id) do
    Enum.reduce(messages, {[], []}, fn message, {matching, to_delete} ->
      case parse_and_check_message_id(message, target_message_id) do
        true ->
          # This message matches our target
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} ->
              {[event_data | matching], [message | to_delete]}

            {:error, reason} ->
              Logger.warning("Failed to parse matching SQS message: #{inspect(reason)}")
              {matching, [message | to_delete]}
          end

        false ->
          # This message doesn't match our search, leave it in queue
          # Visibility timeout will expire and normal SQS worker can process it
          {matching, to_delete}
      end
    end)
  end

  # Delete processed messages from SQS
  defp delete_sqs_messages(queue_url, aws_config, messages) do
    Enum.each(messages, fn message ->
      receipt_handle =
        message["ReceiptHandle"] || message["receiptHandle"] || message["receipt_handle"] ||
          message[:receipt_handle]

      if receipt_handle do
        case ExAws.SQS.delete_message(queue_url, receipt_handle)
             |> ExAws.request(aws_config) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to delete SQS message: #{inspect(reason)}")
        end
      else
        Logger.warning("Message missing ReceiptHandle: #{inspect(message)}")
      end
    end)
  end

  # Helper function to poll DLQ in batches to find specific message (don't delete from DLQ)
  defp poll_dlq_for_message(
         dlq_url,
         target_message_id,
         found_events,
         batch_count,
         max_batches,
         aws_config
       ) do
    if batch_count >= max_batches do
      found_events
    else
      # Poll for messages with visibility timeout (don't delete from DLQ)
      # Use system settings for configuration
      max_messages = get_sqs_max_messages()
      visibility_timeout = get_sqs_visibility_timeout()

      messages =
        ExAws.SQS.receive_message(dlq_url,
          max_number_of_messages: max_messages,
          visibility_timeout: visibility_timeout,
          wait_time_seconds: 2
        )
        |> ExAws.request(aws_config)
        |> case do
          {:ok, %{"Messages" => messages}} when is_list(messages) ->
            messages

          {:ok, %{"messages" => messages}} when is_list(messages) ->
            messages

          {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
            messages

          {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
            messages

          {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
            messages

          {:ok, _response} ->
            []

          error ->
            Logger.warning("DLQ poll error: #{inspect(error)}")
            []
        end

      if Enum.empty?(messages) do
        # No more messages, stop polling
        found_events
      else
        # Process this batch (but don't delete from DLQ)
        matching_messages = process_dlq_batch(messages, target_message_id)
        new_found_events = found_events ++ matching_messages

        if Enum.empty?(matching_messages) do
          # No matches in this batch, continue to next batch
          poll_dlq_for_message(
            dlq_url,
            target_message_id,
            new_found_events,
            batch_count + 1,
            max_batches,
            aws_config
          )
        else
          # Found matches, return immediately
          new_found_events
        end
      end
    end
  end

  # Process a batch of DLQ messages (don't delete from DLQ)
  defp process_dlq_batch(messages, target_message_id) do
    Enum.reduce(messages, [], fn message, matching ->
      case parse_and_check_message_id(message, target_message_id) do
        true ->
          # This message matches our target
          case SQSProcessor.parse_sns_message(message) do
            {:ok, event_data} ->
              [event_data | matching]

            {:error, reason} ->
              Logger.warning("Failed to parse matching DLQ message: #{inspect(reason)}")
              matching
          end

        false ->
          # This message doesn't match
          matching
      end
    end)
  end

  ## --- System Settings ---

  @impl PhoenixKit.Module
  @doc """
  Checks if the email system is enabled.

  Returns true if the "email_enabled" setting is true.

  ## Examples

      iex> PhoenixKit.Modules.Emails.enabled?()
      true
  """
  def enabled? do
    Settings.get_boolean_setting("email_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  @doc """
  Enables the email system.

  Sets the "email_enabled" setting to true.

  ## Examples

      iex> PhoenixKit.Modules.Emails.enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("email_enabled", true, "email_system")
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the email system.

  Sets the "email_enabled" setting to false.

  ## Examples

      iex> PhoenixKit.Modules.Emails.disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("email_enabled", false, "email_system")
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "emails"

  @impl PhoenixKit.Module
  def module_name, do: "Emails"

  @impl PhoenixKit.Module
  def version, do: "0.1.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "emails",
      label: "Emails",
      icon: "📧",
      description: "Email delivery tracking, templates, and analytics"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    alias PhoenixKit.Modules.Emails.Web

    [
      Tab.new!(
        id: :admin_emails,
        label: "Emails",
        icon: "hero-envelope",
        path: "emails/dashboard",
        priority: 510,
        level: :admin,
        permission: "emails",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        subtab_indent: "pl-4",
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Metrics, :index}
      ),
      Tab.new!(
        id: :admin_emails_dashboard,
        label: "Dashboard",
        icon: "hero-chart-bar-square",
        path: "emails/dashboard",
        priority: 511,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Metrics, :index}
      ),
      Tab.new!(
        id: :admin_emails_list,
        label: "Emails",
        icon: "hero-inbox-stack",
        path: "emails",
        priority: 512,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        match: :exact,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Emails, :index}
      ),
      Tab.new!(
        id: :admin_emails_details,
        label: "Email Details",
        icon: "hero-envelope-open",
        path: "emails/email/:id",
        priority: 512,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        visible: false,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Details, :show}
      ),
      Tab.new!(
        id: :admin_emails_templates,
        label: "Templates",
        icon: "hero-document-duplicate",
        path: "emails/templates",
        priority: 513,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Templates, :index}
      ),
      Tab.new!(
        id: :admin_emails_template_new,
        label: "New Template",
        icon: "hero-document-plus",
        path: "emails/templates/new",
        priority: 513,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        visible: false,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.TemplateEditor, :new}
      ),
      Tab.new!(
        id: :admin_emails_template_edit,
        label: "Edit Template",
        icon: "hero-pencil-square",
        path: "emails/templates/:id/edit",
        priority: 513,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        visible: false,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.TemplateEditor, :edit}
      ),
      Tab.new!(
        id: :admin_emails_queue,
        label: "Queue",
        icon: "hero-queue-list",
        path: "emails/queue",
        priority: 514,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Queue, :index}
      ),
      Tab.new!(
        id: :admin_emails_blocklist,
        label: "Blocklist",
        icon: "hero-no-symbol",
        path: "emails/blocklist",
        priority: 515,
        level: :admin,
        permission: "emails",
        parent: :admin_emails,
        gettext_backend: PhoenixKit.Modules.Emails.Gettext,
        live_view: {Web.Blocklist, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs, do: []

  # Contributes to the core "Email Sending" settings page
  # (`/admin/settings/email-sending`) instead of routing its own settings
  # tab — see `PhoenixKit.Module.email_settings_sections/0`. Sender identity
  # (from_name/from_email) is core's own concern now; not duplicated here.
  #
  # "Amazon SES & SQS" used to be a third section here. It is not a peer of
  # the tracker table — it is what one of that table's rows expands into, and
  # is reached through `SQSPollingManager.settings_component/0` now (see
  # `Web.SettingsSections.DeliveryEventTracking`). The component itself is
  # unchanged in kind, only in where it is mounted.
  @impl PhoenixKit.Module
  def email_settings_sections do
    [
      %{
        id: :emails_tracking,
        title: gettext("Email Tracking"),
        permission: "emails",
        component: PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking
      },
      %{
        id: :emails_delivery_event_tracking,
        title: gettext("Delivery Event Tracking"),
        permission: "emails",
        component: PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking
      }
    ]
  end

  @impl PhoenixKit.Module
  def children, do: [PhoenixKit.Modules.Emails.Supervisor]

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKit.Modules.Emails.Migrations

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_emails]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKit.Modules.Emails.Web.Routes

  @migrated_connection_name "Amazon SES (migrated)"

  # Moves plaintext `aws_access_key_id`/`aws_secret_access_key`/`aws_region`
  # Settings into a new encrypted `aws_ses` Integrations connection, and
  # selects it via `emails_aws_integration_uuid`. Idempotent: no-ops once
  # an integration is already selected, or when no legacy credentials exist.
  #
  # Deliberately does NOT delete/blank the old `aws_access_key_id` /
  # `aws_secret_access_key` Settings rows once copied — this is a
  # DOCUMENTED, intentional decision (see PR #16's body, "Operational step
  # after upgrading"), not an oversight: the operator is expected to blank
  # them manually once they've confirmed a real send works through the new
  # Integrations connection. Do not "fix" this by having migrate_legacy/0
  # delete them automatically — an operator who hasn't yet verified the new
  # connection works would otherwise lose their only working credentials.
  #
  # Deliberately does NOT validate the connection against SES — this used
  # to call `Integrations.validate_connection/1` (a live `GetSendQuota`
  # request, up to a 15s timeout) during BOOT migration, blocking startup
  # and requiring network egress before the app could even come up. The
  # credentials came from a config that was already sending mail before
  # this migration ran, so there's nothing to verify here that the send
  # path itself won't verify on the first real send; the connection lands
  # at whatever status `save_setup/3` computes from credential presence
  # (`"configured"`, not `"connected"`) — `get_credentials/1` treats both
  # as usable, so sending is unaffected. The admin's "Test Connection"
  # button on the Integrations page remains available for an operator who
  # wants to confirm it explicitly.
  @impl PhoenixKit.Module
  def migrate_legacy do
    if Settings.get_setting("emails_aws_integration_uuid") in [nil, ""] do
      access_key = Settings.get_setting("aws_access_key_id")
      secret_key = Settings.get_setting("aws_secret_access_key")

      if is_binary(access_key) and access_key != "" and is_binary(secret_key) and
           secret_key != "" do
        uuid = existing_migrated_connection_uuid() || create_migrated_connection!()

        # Persisted immediately once we have a uuid (found or newly
        # created), before the credential write below — a crash here used
        # to leave `emails_aws_integration_uuid` blank, so a retry would
        # call add_connection/2 again and create a second "Amazon SES
        # (migrated)" connection every time. existing_migrated_connection_uuid/0
        # is the belt-and-suspenders half of the same fix: even if a prior
        # crash happened before this very write landed, a connection under
        # this exact name may already exist from that attempt — reuse it.
        Settings.update_setting("emails_aws_integration_uuid", uuid)

        {:ok, _} =
          Integrations.save_setup(uuid, %{
            "access_key" => access_key,
            "secret_key" => secret_key,
            "aws_region" => Settings.get_setting("aws_region") || "us-east-1"
          })

        invalidate_aws_credentials_cache()
      end
    end

    seed_aws_tracking_from_legacy()

    :ok
  end

  # Copies the single global SES/SQS pipeline settings into the per-account
  # `aws_tracking:<uuid>` shape for whichever account `emails_aws_integration_uuid`
  # currently selects — the one account those globals have always described.
  #
  # Idempotent in the way that matters: it only writes when that account has
  # NO tracking settings yet, so an operator who has since edited the
  # per-account pipeline in the UI never gets it overwritten by the legacy
  # globals on the next boot. Runs unconditionally (not only inside the
  # credentials-migration branch above), because the selection can also have
  # been made by hand in the UI, long after that branch stopped applying.
  #
  # A deployment with no selected account keeps working untouched: the
  # legacy fallback in `SQSPollingJob` reads the same globals directly.
  defp seed_aws_tracking_from_legacy do
    uuid = selected_aws_integration_uuid()

    if is_binary(uuid) and is_nil(get_aws_tracking(uuid)) do
      legacy = %{
        "queue_url" => Settings.get_setting("aws_sqs_queue_url"),
        "dlq_url" => Settings.get_setting("aws_sqs_dlq_url"),
        "queue_arn" => Settings.get_setting("aws_sqs_queue_arn"),
        "sns_topic_arn" => Settings.get_setting("aws_sns_topic_arn"),
        "configuration_set" => Settings.get_setting("aws_ses_configuration_set"),
        "region" => get_aws_region()
      }

      # Nothing to carry over (a fresh install that only ever picked a
      # credentials source) — writing a row would just leave an empty
      # `aws_tracking:` key behind for no gain.
      #
      # Judged on the PIPELINE fields only. `region` is deliberately excluded:
      # it resolves through the selected connection, so it is non-blank on any
      # install that has one, and counting it made this guard always true —
      # the row it then wrote described nothing.
      if any_legacy_pipeline_value?(legacy) do
        set_aws_tracking(uuid, legacy)
      end
    end
  end

  defp any_legacy_pipeline_value?(legacy) do
    Enum.any?(aws_tracking_pipeline_fields(), &present?(legacy[&1]))
  end

  defp existing_migrated_connection_uuid do
    case Integrations.find_uuid_by_provider_name({"aws_ses", @migrated_connection_name}) do
      {:ok, uuid} -> uuid
      {:error, _reason} -> nil
    end
  end

  defp create_migrated_connection! do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", @migrated_connection_name)
    uuid
  end

  @doc """
  Checks if full email body saving is enabled.

  Returns true if the "email_save_body" setting is true.

  ## Examples

      iex> PhoenixKit.Modules.Emails.save_body_enabled?()
      false
  """
  def save_body_enabled? do
    Settings.get_boolean_setting("email_save_body", false)
  end

  @doc """
  Enables or disables full email body saving.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_save_body(true)
      {:ok, %Setting{}}
  """
  def set_save_body(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_save_body",
      enabled,
      "email_system"
    )
  end

  @doc """
  Checks if email headers saving is enabled.

  Returns true if the "email_save_headers" setting is true.

  ## Examples

      iex> PhoenixKit.Modules.Emails.save_headers_enabled?()
      false
  """
  def save_headers_enabled? do
    Settings.get_boolean_setting("email_save_headers", false)
  end

  @doc """
  Enables or disables email headers saving.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_save_headers(true)
      {:ok, %Setting{}}
  """
  def set_save_headers(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_save_headers",
      enabled,
      "email_system"
    )
  end

  @doc """
  Checks if AWS SES event management is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Emails.ses_events_enabled?()
      true
  """
  def ses_events_enabled? do
    Settings.get_boolean_setting("email_ses_events", true)
  end

  @doc """
  Enables or disables AWS SES event management.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_ses_events(true)
      {:ok, %Setting{}}
  """
  def set_ses_events(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_ses_events",
      enabled,
      "email_system"
    )
  end

  @doc """
  Checks if placeholder log creation is enabled.

  When enabled, the system creates placeholder logs for events received from AWS SES
  that don't have an existing email log. This can help recover from synchronization issues
  but may mask underlying problems.

  Default: false (recommended for production to expose synchronization issues)

  ## Examples

      iex> PhoenixKit.Modules.Emails.placeholder_logs_enabled?()
      false
  """
  def placeholder_logs_enabled? do
    # Default to false to expose synchronization issues
    # Users can explicitly enable via Settings if needed for development/debugging
    Settings.get_boolean_setting("email_create_placeholder_logs", false)
  end

  @doc """
  Enables or disables placeholder log creation.

  ## Parameters

  - `enabled` - true to enable placeholder logs, false to disable

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_placeholder_logs(false)
      {:ok, %Setting{}}
  """
  def set_placeholder_logs(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_create_placeholder_logs",
      enabled,
      "email_system"
    )
  end

  @doc """
  Gets the configured retention period for emails in days.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_retention_days()
      90
  """
  def get_retention_days do
    Settings.get_integer_setting("email_retention_days", 90)
  end

  @doc """
  Sets the retention period for emails.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_retention_days(180)
      {:ok, %Setting{}}
  """
  def set_retention_days(days) when is_integer(days) and days > 0 do
    Settings.update_setting_with_module(
      "email_retention_days",
      to_string(days),
      "email_system"
    )
  end

  @doc """
  Gets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_ses_configuration_set()
      "my-app-system"
  """
  def get_ses_configuration_set do
    Settings.get_setting_cached("aws_ses_configuration_set", nil)
  end

  @doc """
  Sets the AWS SES configuration set name.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_ses_configuration_set("my-system-set")
      {:ok, %Setting{}}
  """
  def set_ses_configuration_set(config_set_name) when is_binary(config_set_name) do
    Settings.update_setting_with_module(
      "aws_ses_configuration_set",
      config_set_name,
      "email_system"
    )
  end

  @doc """
  Gets the sampling rate for email logging (percentage).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sampling_rate()
      100  # Log 100% of emails
  """
  def get_sampling_rate do
    Settings.get_integer_setting("email_sampling_rate", 100)
  end

  @doc """
  Sets the sampling rate for email logging.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sampling_rate(80)  # Log 80% of emails
      {:ok, %Setting{}}
  """
  def set_sampling_rate(percentage)
      when is_integer(percentage) and percentage >= 0 and percentage <= 100 do
    Settings.update_setting_with_module(
      "email_sampling_rate",
      to_string(percentage),
      "email_system"
    )
  end

  @doc """
  Sets the number of days after which to compress email bodies.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_compress_after_days(30)
      {:ok, %Setting{}}
  """
  def set_compress_after_days(days) when is_integer(days) and days >= 7 and days <= 365 do
    Settings.update_setting_with_module(
      "email_compress_body",
      to_string(days),
      "email_system"
    )
  end

  @doc """
  Enables or disables S3 archival for old email data.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_s3_archival(true)
      {:ok, %Setting{}}
  """
  def set_s3_archival(enabled) when is_boolean(enabled) do
    Settings.update_boolean_setting_with_module(
      "email_archive_to_s3",
      enabled,
      "email_system"
    )
  end

  @doc """
  Gets the S3 bucket archives are written to, or `nil` when unset.
  """
  def get_s3_bucket do
    case Settings.get_setting("email_s3_bucket") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Sets the S3 bucket archives are written to. A blank string clears it.

  The bucket had a reader and no writer, so archival could never be pointed
  anywhere: enabling it always failed with `:no_bucket_configured`.

  Clearing DELETES the row rather than storing `""` — the settings changeset
  rejects an empty value outright ("must provide either value or value_json"),
  so a blank write would otherwise fail instead of unsetting.
  """
  def set_s3_bucket(bucket) when is_binary(bucket) do
    put_or_clear_setting("email_s3_bucket", bucket)
  end

  @doc """
  Gets the uuid of the Integrations connection whose credentials sign archive
  uploads, or `nil` to leave ExAws to its own resolution chain.
  """
  def get_s3_integration do
    case Settings.get_setting("email_s3_integration") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Sets the Integrations connection used for archive uploads. `""` clears it,
  which falls back to the environment, an instance profile, or a task role.
  """
  def set_s3_integration(uuid) when is_binary(uuid) do
    put_or_clear_setting("email_s3_integration", uuid)
  end

  # Clearing a setting that was never stored is not an error — the caller asked
  # for "unset" and unset is what it gets. `delete_setting/1` reports
  # `{:error, :not_found}` for that case, which would make a first-time clear
  # look like a failed write.
  defp put_or_clear_setting(key, value) do
    case String.trim(value) do
      "" ->
        case Settings.delete_setting(key) do
          {:error, :not_found} -> {:ok, :cleared}
          {:ok, _} -> {:ok, :cleared}
          other -> other
        end

      trimmed ->
        Settings.update_setting_with_module(key, trimmed, "email_system")
    end
  end

  ## --- AWS SQS Configuration ---

  @doc """
  Gets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sns_topic_arn()
      "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events"
  """
  def get_sns_topic_arn do
    Settings.get_setting_cached("aws_sns_topic_arn", nil)
  end

  @doc """
  Sets the AWS SNS Topic ARN for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sns_topic_arn("arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events")
      {:ok, %Setting{}}
  """
  def set_sns_topic_arn(topic_arn) when is_binary(topic_arn) do
    Settings.update_setting_with_module(
      "aws_sns_topic_arn",
      topic_arn,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_queue_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue"
  """
  def get_sqs_queue_url do
    Settings.get_setting_cached("aws_sqs_queue_url", nil)
  end

  @doc """
  Sets the AWS SQS Queue URL for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_url(queue_url) when is_binary(queue_url) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_url",
      queue_url,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_queue_arn()
      "arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue"
  """
  def get_sqs_queue_arn do
    Settings.get_setting_cached("aws_sqs_queue_arn", nil)
  end

  @doc """
  Sets the AWS SQS Queue ARN for email events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_queue_arn("arn:aws:sqs:eu-north-1:123456789012:phoenixkit-email-queue")
      {:ok, %Setting{}}
  """
  def set_sqs_queue_arn(queue_arn) when is_binary(queue_arn) do
    Settings.update_setting_with_module(
      "aws_sqs_queue_arn",
      queue_arn,
      "email_system"
    )
  end

  @doc """
  Gets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_dlq_url()
      "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq"
  """
  def get_sqs_dlq_url do
    Settings.get_setting_cached("aws_sqs_dlq_url", nil)
  end

  @doc """
  Sets the AWS SQS Dead Letter Queue URL.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_dlq_url("https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-dlq")
      {:ok, %Setting{}}
  """
  def set_sqs_dlq_url(dlq_url) when is_binary(dlq_url) do
    Settings.update_setting_with_module(
      "aws_sqs_dlq_url",
      dlq_url,
      "email_system"
    )
  end

  @doc """
  Gets the AWS region for SES and SQS services.

  Priority: selected Integrations connection → Settings Database →
  Environment Variables (see `aws_ses_credentials/0`).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_aws_region()
      "eu-north-1"
  """
  def get_aws_region do
    Map.get(aws_ses_credentials(), "aws_region") || legacy_aws_region()
  end

  defp legacy_aws_region do
    Settings.get_setting_cached("aws_region", AWS.region())
  end

  @doc """
  Sets the AWS region for SES and SQS services.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_aws_region("eu-north-1")
      {:ok, %Setting{}}
  """
  def set_aws_region(region) when is_binary(region) do
    Settings.update_setting_with_module(
      "aws_region",
      region,
      "email_system"
    )
  end

  ## --- SQS Worker Configuration ---

  @doc """
  Checks if SQS polling is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Emails.sqs_polling_enabled?()
      true
  """
  def sqs_polling_enabled? do
    Settings.get_boolean_setting("sqs_polling_enabled", false)
  end

  @doc """
  Enables or disables SQS polling.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_polling(true)
      {:ok, %Setting{}}
  """
  def set_sqs_polling(enabled) when is_boolean(enabled) do
    Settings.update_setting_with_module(
      "sqs_polling_enabled",
      to_string(enabled),
      "email_system"
    )
  end

  @doc """
  Gets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_polling_interval()
      5000  # 5 seconds
  """
  def get_sqs_polling_interval do
    Settings.get_integer_setting("sqs_polling_interval_ms", 5000)
  end

  @doc """
  Sets the SQS polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_polling_interval(3000)  # 3 seconds
      {:ok, %Setting{}}
  """
  def set_sqs_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Settings.update_setting_with_module(
      "sqs_polling_interval_ms",
      to_string(interval_ms),
      "email_system"
    )
  end

  @doc """
  Gets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_max_messages()
      10
  """
  def get_sqs_max_messages do
    Settings.get_integer_setting("sqs_max_messages_per_poll", 10)
  end

  @doc """
  Sets the maximum number of SQS messages to receive per polling cycle.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_max_messages(20)
      {:ok, %Setting{}}
  """
  def set_sqs_max_messages(max_messages)
      when is_integer(max_messages) and max_messages > 0 and max_messages <= 10 do
    Settings.update_setting_with_module(
      "sqs_max_messages_per_poll",
      to_string(max_messages),
      "email_system"
    )
  end

  @doc """
  Gets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_visibility_timeout()
      300  # 5 minutes
  """
  def get_sqs_visibility_timeout do
    Settings.get_integer_setting("sqs_visibility_timeout", 300)
  end

  @doc """
  Sets the SQS message visibility timeout in seconds.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_visibility_timeout(600)  # 10 minutes
      {:ok, %Setting{}}
  """
  def set_sqs_visibility_timeout(timeout_seconds)
      when is_integer(timeout_seconds) and timeout_seconds > 0 do
    Settings.update_setting_with_module(
      "sqs_visibility_timeout",
      to_string(timeout_seconds),
      "email_system"
    )
  end

  @doc """
  Gets comprehensive SQS configuration.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_config()
      %{
        sns_topic_arn: "arn:aws:sns:...",
        queue_url: "https://sqs.eu-north-1.amazonaws.com/...",
        polling_enabled: true,
        polling_interval_ms: 5000,
        max_messages_per_poll: 10
      }
  """
  def get_sqs_config do
    %{
      sns_topic_arn: get_sns_topic_arn(),
      queue_url: get_sqs_queue_url(),
      queue_arn: get_sqs_queue_arn(),
      dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      aws_access_key_id: get_aws_access_key(),
      aws_secret_access_key: get_aws_secret_key(),
      polling_enabled: sqs_polling_enabled?(),
      polling_interval_ms: get_sqs_polling_interval(),
      max_messages_per_poll: get_sqs_max_messages(),
      visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  ## --- Brevo Event Polling Configuration ---

  @doc """
  Checks if Brevo event polling is enabled.

  Unlike SQS (which separates "event tracking" from "polling mechanism"
  into two flags), Brevo has only the one mechanism — this single flag
  gates both.

  ## Examples

      iex> PhoenixKit.Modules.Emails.brevo_events_enabled?()
      false
  """
  def brevo_events_enabled? do
    Settings.get_boolean_setting("brevo_events_enabled", false)
  end

  @doc """
  Enables or disables Brevo event polling.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_brevo_events_enabled(true)
      {:ok, %Setting{}}
  """
  def set_brevo_events_enabled(enabled) when is_boolean(enabled) do
    Settings.update_setting_with_module(
      "brevo_events_enabled",
      to_string(enabled),
      "email_system"
    )
  end

  @doc """
  Gets the Brevo polling interval in milliseconds.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_brevo_polling_interval()
      120_000
  """
  def get_brevo_polling_interval do
    Settings.get_integer_setting("brevo_polling_interval_ms", 120_000)
  end

  @doc """
  Sets the Brevo polling interval in milliseconds (minimum 30 000 — Brevo's
  rate limits are looser than SQS's long-poll cadence, so this floor is
  higher than SQS's 1 000ms).

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_brevo_polling_interval(60_000)
      {:ok, %Setting{}}
  """
  def set_brevo_polling_interval(interval_ms)
      when is_integer(interval_ms) and interval_ms >= 30_000 do
    Settings.update_setting_with_module(
      "brevo_polling_interval_ms",
      to_string(interval_ms),
      "email_system"
    )
  end

  @doc """
  Gets the timestamp of the last completed Brevo polling cycle, if any.
  Observability only — dedup/idempotency is enforced at the DB level by
  `Event`'s unique indexes, this is not used as a fetch cursor.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_brevo_last_polled_at()
      "2026-07-19T12:00:00Z"
  """
  def get_brevo_last_polled_at do
    Settings.get_setting("brevo_last_polled_at", nil)
  end

  @doc """
  Records the timestamp of the last completed Brevo polling cycle.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_brevo_last_polled_at(DateTime.utc_now())
      {:ok, %Setting{}}
  """
  def set_brevo_last_polled_at(%DateTime{} = timestamp) do
    Settings.update_setting_with_module(
      "brevo_last_polled_at",
      DateTime.to_iso8601(timestamp),
      "email_system"
    )
  end

  @doc """
  Integration uuids the operator has explicitly opted OUT of Brevo event
  polling — an empty list (the default) means every active Brevo
  integration gets polled. `BrevoPollingJob` reads this fresh every
  cycle (no cache invalidation needed).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_brevo_polling_excluded_integrations()
      []
  """
  def get_brevo_polling_excluded_integrations do
    Settings.get_setting("brevo_polling_excluded_integrations", "")
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Sets the list of Brevo integration uuids excluded from polling.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_brevo_polling_excluded_integrations(["uuid-1"])
      {:ok, %Setting{}}
  """
  def set_brevo_polling_excluded_integrations(uuids) when is_list(uuids) do
    Settings.update_setting_with_module(
      "brevo_polling_excluded_integrations",
      Enum.join(uuids, ","),
      "email_system"
    )
  end

  @brevo_watermark_prefix "brevo_watermark:"

  @doc """
  The stored Brevo poll watermark for one integration — how far
  `BrevoPollingJob` has progressed through that integration's event
  stream, as `%{date: Date.t(), offset: non_neg_integer()}`. `nil` if
  this integration has never been polled under the watermark scheme yet
  (cold start).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_brevo_watermark("some-uuid")
      %{date: ~D[2026-07-19], offset: 2500}
  """
  def get_brevo_watermark(integration_uuid) when is_binary(integration_uuid) do
    case Settings.get_json_setting(@brevo_watermark_prefix <> integration_uuid, nil) do
      %{"date" => date_str, "offset" => offset}
      when is_binary(date_str) and is_integer(offset) and offset >= 0 ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> %{date: date, offset: offset}
          {:error, _reason} -> nil
        end

      _other ->
        nil
    end
  end

  @doc """
  Persists one integration's Brevo poll watermark.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_brevo_watermark("some-uuid", ~D[2026-07-19], 2500)
      {:ok, %Setting{}}
  """
  def set_brevo_watermark(integration_uuid, %Date{} = date, offset)
      when is_binary(integration_uuid) and is_integer(offset) and offset >= 0 do
    Settings.update_json_setting_with_module(
      @brevo_watermark_prefix <> integration_uuid,
      %{"date" => Date.to_iso8601(date), "offset" => offset},
      "email_system"
    )
  end

  @doc """
  Every integration uuid that currently has a stored Brevo watermark —
  used by `BrevoPollingJob` to prune watermarks for integrations that
  are no longer active (deleted, or opted out of polling), so those
  settings rows don't accumulate forever.

  ## Examples

      iex> PhoenixKit.Modules.Emails.list_brevo_watermark_integration_uuids()
      ["some-uuid"]
  """
  def list_brevo_watermark_integration_uuids do
    @brevo_watermark_prefix
    |> Settings.get_json_settings_by_prefix()
    |> Enum.map(fn {key, _json} -> String.replace_prefix(key, @brevo_watermark_prefix, "") end)
  end

  @doc """
  Deletes one integration's stored Brevo watermark, if any. A no-op
  (still `{:ok, ...}`-shaped via the underlying delete) if none exists.

  ## Examples

      iex> PhoenixKit.Modules.Emails.delete_brevo_watermark("some-uuid")
      {:ok, %Setting{}}
  """
  def delete_brevo_watermark(integration_uuid) when is_binary(integration_uuid) do
    Settings.delete_setting(@brevo_watermark_prefix <> integration_uuid)
  end

  ## --- AWS SES per-account tracking configuration ---

  @aws_tracking_prefix "aws_tracking:"

  @aws_tracking_fields ~w(queue_url dlq_url queue_arn sns_topic_arn configuration_set region)

  @doc """
  The per-account SES/SQS tracking pipeline for one `aws_ses` integration —
  the multi-account replacement for the single global `aws_sqs_queue_url` /
  `aws_ses_configuration_set` / … settings, stored as one JSON setting per
  account under the `aws_tracking:<integration_uuid>` key (the same
  prefix-keyed shape `get_brevo_watermark/1` uses for its cursor).

  Returns a map with every key in #{inspect(@aws_tracking_fields)} (missing
  or blank entries come back as `nil`), or `nil` when this account has no
  tracking settings at all — which is what the legacy single-queue fallback
  in `SQSPollingJob` keys off, so an existing env-configured deployment
  keeps polling exactly as before.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_aws_tracking("some-uuid")
      %{queue_url: "https://sqs.eu-north-1.amazonaws.com/1/q", region: "eu-north-1", ...}
  """
  @spec get_aws_tracking(String.t()) :: map() | nil
  def get_aws_tracking(integration_uuid) when is_binary(integration_uuid) do
    case Settings.get_json_setting(@aws_tracking_prefix <> integration_uuid, nil) do
      json when is_map(json) -> decode_aws_tracking(json)
      _other -> nil
    end
  end

  @doc """
  Persists one account's SES/SQS tracking pipeline. Accepts string- or
  atom-keyed attrs; unknown keys are dropped and blank values are stored as
  `nil`, so the stored JSON is always exactly the
  #{inspect(@aws_tracking_fields)} shape `get_aws_tracking/1` reads back.

  Callers that change this must also reconcile the SES tracker (a queue URL
  appearing/disappearing changes `SQSPollingManager.eligible?/0`) — see
  `PhoenixKit.Modules.Emails.EventTrackerReconciler.reconcile_tracker/1`.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_aws_tracking("some-uuid", %{"queue_url" => "https://..."})
      {:ok, %Setting{}}
  """
  @spec set_aws_tracking(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def set_aws_tracking(integration_uuid, attrs)
      when is_binary(integration_uuid) and is_map(attrs) do
    json =
      Map.new(@aws_tracking_fields, fn field ->
        {field, normalize_aws_tracking_value(attrs, field)}
      end)

    Settings.update_json_setting_with_module(
      @aws_tracking_prefix <> integration_uuid,
      json,
      "email_system"
    )
  end

  @doc """
  Every integration uuid that currently has stored AWS tracking settings —
  used by `SQSPollingJob` to prune settings for integrations that no longer
  exist, so those rows don't accumulate forever.

  ## Examples

      iex> PhoenixKit.Modules.Emails.list_aws_tracking_integration_uuids()
      ["some-uuid"]
  """
  @spec list_aws_tracking_integration_uuids() :: [String.t()]
  def list_aws_tracking_integration_uuids do
    @aws_tracking_prefix
    |> Settings.get_json_settings_by_prefix()
    |> Enum.map(fn {key, _json} -> String.replace_prefix(key, @aws_tracking_prefix, "") end)
  end

  @doc """
  Deletes one account's stored AWS tracking settings, if any.

  ## Examples

      iex> PhoenixKit.Modules.Emails.delete_aws_tracking("some-uuid")
      {:ok, %Setting{}}
  """
  @spec delete_aws_tracking(String.t()) :: {:ok, term()} | {:error, term()}
  def delete_aws_tracking(integration_uuid) when is_binary(integration_uuid) do
    Settings.delete_setting(@aws_tracking_prefix <> integration_uuid)
  end

  @doc false
  # The field names `get_aws_tracking/1` returns and `set_aws_tracking/2`
  # accepts. Public (as @doc false) so the settings UI and the tests can
  # iterate the same list instead of re-typing it.
  @spec aws_tracking_fields() :: [String.t()]
  def aws_tracking_fields, do: @aws_tracking_fields

  # Everything aws_tracking_fields/0 lists except `region`, which describes
  # WHERE an account lives rather than WHAT tracking pipeline it has — see
  # `seed_aws_tracking_from_legacy/0`. A function, not an attribute, only
  # because its one caller is defined earlier in the file than this.
  defp aws_tracking_pipeline_fields, do: @aws_tracking_fields -- ["region"]

  defp decode_aws_tracking(json) do
    Map.new(@aws_tracking_fields, fn field ->
      {String.to_atom(field), blank_to_nil(Map.get(json, field))}
    end)
  end

  defp normalize_aws_tracking_value(attrs, field) do
    attrs
    |> Map.get(field, Map.get(attrs, String.to_atom(field)))
    |> blank_to_nil()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  @doc """
  Integration uuids the operator has explicitly opted OUT of SQS event
  polling — an empty list (the default) means every active `aws_ses`
  integration gets polled. `SQSPollingJob` reads this fresh every cycle (no
  cache invalidation needed). Same comma-separated storage format as
  `get_brevo_polling_excluded_integrations/0`.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_sqs_polling_excluded_integrations()
      []
  """
  @spec get_sqs_polling_excluded_integrations() :: [String.t()]
  def get_sqs_polling_excluded_integrations do
    Settings.get_setting("sqs_polling_excluded_integrations", "")
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Sets the list of `aws_ses` integration uuids excluded from SQS polling.

  ## Examples

      iex> PhoenixKit.Modules.Emails.set_sqs_polling_excluded_integrations(["uuid-1"])
      {:ok, %Setting{}}
  """
  @spec set_sqs_polling_excluded_integrations([String.t()]) :: {:ok, term()} | {:error, term()}
  def set_sqs_polling_excluded_integrations(uuids) when is_list(uuids) do
    Settings.update_setting_with_module(
      "sqs_polling_excluded_integrations",
      Enum.join(uuids, ","),
      "email_system"
    )
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the current email system configuration.

  Returns a map with all current settings.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_config()
      %{
        enabled: true,
        save_body: false,
        ses_events: true,
        retention_days: 90,
        sampling_rate: 100,
        ses_configuration_set: "my-system",
        sns_topic_arn: "arn:aws:sns:eu-north-1:123456789012:phoenixkit-email-events",
        sqs_queue_url: "https://sqs.eu-north-1.amazonaws.com/123456789012/phoenixkit-email-queue",
        sqs_polling_enabled: false,
        aws_region: "eu-north-1"
      }
  """
  def get_config do
    %{
      enabled: enabled?(),
      save_body: save_body_enabled?(),
      ses_events: ses_events_enabled?(),
      retention_days: get_retention_days(),
      sampling_rate: get_sampling_rate(),
      ses_configuration_set: get_ses_configuration_set(),
      compress_after_days: get_compress_after_days(),
      archive_to_s3: s3_archival_enabled?(),
      # AWS SQS Configuration
      sns_topic_arn: get_sns_topic_arn(),
      sqs_queue_url: get_sqs_queue_url(),
      sqs_queue_arn: get_sqs_queue_arn(),
      sqs_dlq_url: get_sqs_dlq_url(),
      aws_region: get_aws_region(),
      # SQS Worker Configuration
      sqs_polling_enabled: sqs_polling_enabled?(),
      sqs_polling_interval_ms: get_sqs_polling_interval(),
      sqs_max_messages_per_poll: get_sqs_max_messages(),
      sqs_visibility_timeout: get_sqs_visibility_timeout()
    }
  end

  ## --- Email Log Management ---

  @doc """
  Lists emails with optional filters.

  ## Options

  - `:status` - Filter by status (sent, delivered, bounced, etc.)
  - `:campaign_id` - Filter by campaign
  - `:template_name` - Filter by template
  - `:provider` - Filter by email provider
  - `:from_date` - Emails sent after this date
  - `:to_date` - Emails sent before this date
  - `:recipient` - Filter by recipient email
  - `:limit` - Limit results (default: 50)
  - `:offset` - Offset for pagination

  ## Examples

      iex> PhoenixKit.Modules.Emails.list_logs(%{status: "bounced", limit: 10})
      [%Log{}, ...]
  """
  def list_logs(filters \\ %{}) do
    if enabled?() do
      Log.list_logs(filters)
    else
      []
    end
  end

  @doc """
  Counts emails with optional filtering (without loading all records).

  ## Parameters

  - `filters` - Map of filters to apply (optional)

  ## Examples

      iex> PhoenixKit.Modules.Emails.count_logs(%{status: "bounced"})
      42
  """
  def count_logs(filters \\ %{}) do
    if enabled?() do
      Log.count_logs(filters)
    else
      0
    end
  end

  @doc """
  Gets a single email log by ID. Returns `nil` if not found or system is disabled.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_log("018f1234-5678-7890-abcd-ef1234567890")
      %Log{}

      iex> PhoenixKit.Modules.Emails.get_log("nonexistent")
      nil
  """
  def get_log(id) do
    if enabled?() do
      Log.get_log(id)
    end
  end

  @doc """
  Gets a single email log by ID.

  Raises `Ecto.NoResultsError` if the log does not exist or system is disabled.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_log!("018f1234-5678-7890-abcd-ef1234567890")
      %Log{}
  """
  def get_log!(id) do
    ensure_enabled!()
    Log.get_log!(id)
  end

  @doc """
  Gets an email log by message ID.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_log_by_message_id("msg-abc123")
      {:ok, %Log{}}

      iex> PhoenixKit.Modules.Emails.get_log_by_message_id("nonexistent")
      {:error, :not_found}
  """
  def get_log_by_message_id(message_id) when is_binary(message_id) do
    if enabled?() do
      case Log.get_log_by_message_id(message_id) do
        nil -> {:error, :not_found}
        log -> {:ok, log}
      end
    else
      {:error, :system_disabled}
    end
  end

  @doc """
  Whether an email log exists for `message_id`, matched against either the
  internal `message_id` or the provider `aws_message_id` column.

  A cheap existence check (no struct load); `false` when the system is
  disabled or the id is not a binary. Used by the Brevo poller to skip
  events for mail this app never sent — the account may be shared with
  other senders.
  """
  def email_log_exists?(message_id) when is_binary(message_id) do
    # The `enabled?()` half decides nothing for today's only caller —
    # BrevoPollingJob.perform/1 returns before any event processing when the
    # system is off — but this is a public function, so it keeps the guard
    # instead of assuming every future caller pre-checks.
    enabled?() and Log.exists_by_any_message_id?(message_id)
  end

  def email_log_exists?(_), do: false

  @doc """
  Creates an email log if system is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Emails.create_log(%{
        message_id: "abc123",
        to: "user@example.com",
        from: "app@example.com"
      })
      {:ok, %Log{}}
  """
  def create_log(attrs \\ %{}) do
    attrs = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs

    if enabled?() and should_log_email?(attrs) do
      # Add system-level defaults
      attrs =
        Map.merge(attrs, %{
          # Only fill in the global default when the caller resolved nothing:
          # `Interceptor.extract_email_data/2` now resolves a PER-ACCOUNT
          # configuration set (that is the name actually put on the wire), and
          # overwriting it here would make the stored field disagree with the
          # header that was sent.
          configuration_set: Map.get(attrs, :configuration_set) || get_ses_configuration_set(),
          body_full:
            if(save_body_enabled?() and Map.get(attrs, :body_full),
              do: Map.get(attrs, :body_full),
              else: nil
            ),
          headers: Map.get(attrs, :headers) || %{}
        })

      Log.create_log(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Updates the status of an email log.

  ## Examples

      iex> PhoenixKit.Modules.Emails.update_log_status(log, "delivered")
      {:ok, %Log{}}
  """
  def update_log_status(log, status) when is_binary(status) do
    if enabled?() do
      Log.update_status(log, status)
    else
      {:ok, log}
    end
  end

  @doc """
  Deletes an email log.

  ## Examples

      iex> log = PhoenixKit.Modules.Emails.get_log!(1)
      iex> PhoenixKit.Modules.Emails.delete_log(log)
      {:ok, %Log{}}
  """
  def delete_log(%Log{} = log) do
    if enabled?() do
      Log.delete_log(log)
    else
      {:ok, log}
    end
  end

  ## --- Event Management ---

  @doc """
  Creates an email system event.

  ## Examples

      iex> PhoenixKit.Modules.Emails.create_event(%{
        email_log_uuid: log.uuid,
        event_type: "open"
      })
      {:ok, %Event{}}
  """
  def create_event(attrs \\ %{}) do
    if enabled?() and ses_events_enabled?() do
      Event.create_event(attrs)
    else
      {:ok, :skipped}
    end
  end

  @doc """
  Lists events for a specific email log.

  ## Examples

      iex> PhoenixKit.Modules.Emails.list_events_for_log("550e8400-e29b-41d4-a716-446655440000")
      [%Event{}, ...]
  """
  def list_events_for_log(email_log_uuid) when is_binary(email_log_uuid) do
    if enabled?() do
      Event.for_email_log(email_log_uuid)
    else
      []
    end
  end

  @doc """
  Processes an incoming webhook event (typically from AWS SES).

  ## Examples

      iex> webhook_data = %{
        "eventType" => "bounce",
        "mail" => %{"messageId" => "abc123"}
      }
      iex> PhoenixKit.Modules.Emails.process_webhook_event(webhook_data)
      {:ok, %Event{}}
  """
  def process_webhook_event(webhook_data) when is_map(webhook_data) do
    if enabled?() and ses_events_enabled?() do
      case extract_message_id(webhook_data) do
        nil ->
          {:error, :message_id_not_found}

        message_id ->
          case get_log_by_message_id(message_id) do
            {:error, :not_found} ->
              {:error, :email_log_not_found}

            {:ok, email_log} ->
              process_event_for_log(email_log, webhook_data)

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:ok, :skipped}
    end
  end

  ## --- Analytics & Metrics ---

  @doc """
  Gets overall system statistics for a time period.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_system_stats(:last_30_days)
      %{
        total_sent: 5000,
        delivered: 4850,
        bounced: 150,
        opened: 1200,
        clicked: 240,
        delivery_rate: 97.0,
        bounce_rate: 3.0,
        open_rate: 24.7,
        click_rate: 20.0
      }
  """
  def get_system_stats(period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)

      basic_stats = Log.get_stats_for_period(start_date, end_date)

      Map.merge(basic_stats, %{
        # Add aliases for email_stats.ex compatibility
        complaints: basic_stats.complained,
        total_opened: basic_stats.opened,
        total_clicked: basic_stats.clicked,
        # Calculate percentages
        delivery_rate: safe_percentage(basic_stats.delivered, basic_stats.total_sent),
        bounce_rate: safe_percentage(basic_stats.bounced, basic_stats.total_sent),
        complaint_rate: safe_percentage(basic_stats.complained, basic_stats.total_sent),
        open_rate: safe_percentage(basic_stats.opened, basic_stats.delivered),
        click_rate: safe_percentage(basic_stats.clicked, basic_stats.opened),
        failure_rate: safe_percentage(basic_stats.failed, basic_stats.total_sent)
      })
    else
      %{}
    end
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_engagement_metrics(:last_7_days)
      %{
        avg_open_rate: 24.5,
        avg_click_rate: 4.2,
        bounce_rate: 2.8,
        engagement_trend: :increasing
      }
  """
  def get_engagement_metrics(period \\ :last_30_days) do
    if enabled?() do
      Log.get_engagement_metrics(period)
    else
      %{}
    end
  end

  @doc """
  Gets daily delivery trend data for chart visualization.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_daily_delivery_trends(:last_7_days)
      %{
        labels: ["2024-09-01", "2024-09-02", ...],
        delivered: [120, 190, 300, ...],
        bounced: [5, 10, 15, ...]
      }
  """
  def get_daily_delivery_trends(period \\ :last_7_days) do
    if enabled?() do
      Log.get_daily_delivery_trends(period)
    else
      %{labels: [], delivered: [], bounced: [], total_sent: []}
    end
  end

  @doc """
  Gets statistics for a specific campaign.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_campaign_stats("newsletter_2024")
      %{
        total_sent: 1000,
        delivery_rate: 98.5,
        open_rate: 25.2,
        click_rate: 4.8
      }
  """
  def get_campaign_stats(campaign_id) when is_binary(campaign_id) do
    if enabled?() do
      Log.get_campaign_stats(campaign_id)
    else
      %{}
    end
  end

  @doc """
  Gets template-specific performance metrics.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_template_stats(:last_30_days)
      %{
        "welcome_email" => %{sent: 100, delivered: 95, opened: 45, clicked: 12},
        "password_reset" => %{sent: 50, delivered: 48, opened: 30, clicked: 8}
      }
  """
  def get_template_stats(period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)

      # Get basic stats grouped by template
      basic_stats =
        Log
        |> where([l], l.sent_at >= ^start_date and l.sent_at <= ^end_date)
        |> where([l], not is_nil(l.template_name))
        |> group_by([l], l.template_name)
        |> select([l], {
          l.template_name,
          %{
            sent: count(l.uuid),
            delivered: sum(fragment("CASE WHEN ? = ? THEN 1 ELSE 0 END", l.status, "delivered")),
            opened: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", l.opened_at)),
            clicked: sum(fragment("CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END", l.clicked_at))
          }
        })
        |> repo().all()
        |> Map.new()

      basic_stats
    else
      %{}
    end
  end

  @doc """
  Gets provider-specific performance metrics.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_provider_performance(:last_7_days)
      %{
        "aws_ses" => %{delivery_rate: 98.5, bounce_rate: 1.5},
        "smtp" => %{delivery_rate: 95.0, bounce_rate: 5.0}
      }
  """
  def get_provider_performance(period \\ :last_7_days) do
    if enabled?() do
      Log.get_provider_performance(period)
    else
      %{}
    end
  end

  @doc """
  Gets geographic distribution of engagement events.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_geo_stats("open", :last_30_days)
      %{"US" => 500, "CA" => 200, "UK" => 150}
  """
  def get_geo_stats(event_type, period \\ :last_30_days) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      Event.get_geo_distribution(event_type, start_date, end_date)
    else
      %{}
    end
  end

  @doc """
  Gets the most clicked links for a time period.

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_top_links(:last_30_days, 10)
      [%{url: "https://example.com/product", clicks: 150}, ...]
  """
  def get_top_links(period \\ :last_30_days, limit \\ 10) do
    if enabled?() do
      {start_date, end_date} = get_period_dates(period)
      Event.get_top_clicked_links(start_date, end_date, limit)
    else
      []
    end
  end

  ## --- Maintenance Functions ---

  @doc """
  Removes emails older than the specified number of days.

  Uses the system retention setting if no days specified.

  ## Examples

      iex> PhoenixKit.Modules.Emails.cleanup_old_logs()
      {150, nil}  # Deleted 150 records

      iex> PhoenixKit.Modules.Emails.cleanup_old_logs(180)
      {75, nil}   # Deleted 75 records older than 180 days
  """
  def cleanup_old_logs(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_retention_days()
      # While archival is RUNNABLE, a row it has not shipped yet is not
      # cleanup's to delete — otherwise the two jobs race over the same cutoff
      # and the loser is data the operator believed was in cold storage.
      #
      # "Runnable" is deliberately stricter than "enabled". Gating on the
      # toggle alone meant that flipping it on and forgetting the bucket
      # stopped retention cleanup permanently and silently: nothing can ever
      # stamp a row, so nothing is ever deletable, and the table grows without
      # bound while the settings page reports a retention period it is no
      # longer enforcing. A half-configured feature must not disable a working
      # one.
      Log.cleanup_old_logs(days, require_archived: archival_runnable?())
    else
      {0, nil}
    end
  end

  # Even when archival IS runnable the hold-back is worth saying out loud: if
  # the host never added the crontab entry, rows pile up behind a job that
  # never runs, and the only symptom is a retention period that quietly stopped
  # applying.
  defp archival_runnable? do
    if s3_archival_enabled?() and get_s3_bucket() != nil do
      warn_if_withholding()
      true
    else
      false
    end
  end

  defp warn_if_withholding do
    case Log.count_unarchived_past_retention(get_retention_days()) do
      0 ->
        :ok

      count ->
        Logger.warning(
          "Emails retention: #{count} logs past the retention period are being kept " <>
            "because S3 archival has not shipped them yet. If nothing is uploading, " <>
            "check that ArchiveWorker is in the host Oban crontab."
        )
    end
  end

  @doc """
  Compresses body_full field for old emails to save storage.

  ## Examples

      iex> PhoenixKit.Modules.Emails.compress_old_bodies()
      {25, nil}  # Compressed 25 records

      iex> PhoenixKit.Modules.Emails.compress_old_bodies(60)
      {40, nil}  # Compressed 40 records older than 60 days
  """
  def compress_old_bodies(days_old \\ nil) do
    if enabled?() do
      days = days_old || get_compress_after_days()
      Log.compress_old_bodies(days)
    else
      {0, nil}
    end
  end

  @doc """
  Archives old emails to S3 if archival is enabled.

  Delegates to `PhoenixKit.Modules.Emails.Archiver.archive_to_s3/2`, which is
  where the upload actually happens. Until this delegation existed the function
  selected the rows and returned them untouched, so archival reported success
  having written nothing to S3.

  `opts` are the archiver's: `:bucket`, `:prefix`, `:batch_size`, `:format`,
  `:include_events`, `:delete_after_archive`.

  ## Examples

      iex> PhoenixKit.Modules.Emails.archive_to_s3()
      {:ok, 100}

      iex> PhoenixKit.Modules.Emails.archive_to_s3(180, delete_after_archive: true)
      {:ok, 42}
  """
  def archive_to_s3(days_old \\ nil, opts \\ []) do
    if enabled?() and s3_archival_enabled?() do
      days = days_old || get_retention_days()
      Archiver.archive_to_s3(days, opts)
    else
      {:ok, :skipped}
    end
  end

  ## --- Private Helper Functions ---

  # Ensure the system is enabled, raise if not
  defp ensure_enabled! do
    unless enabled?() do
      raise "Email system is not enabled"
    end
  end

  # Determine if an email should be logged based on sampling rate
  defp should_log_email?(_attrs) do
    sampling_rate = get_sampling_rate()

    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on message_id or random
      :rand.uniform(100) <= sampling_rate
    end
  end

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  # Extract message ID from webhook data
  defp extract_message_id(webhook_data) do
    webhook_data["mail"]["messageId"] ||
      webhook_data["messageId"] ||
      get_in(webhook_data, ["mail", "commonHeaders", "messageId"])
  end

  # Process a specific event for an email log
  defp process_event_for_log(email_log, webhook_data) do
    case Event.create_from_ses_webhook(email_log, webhook_data) do
      {:ok, event} ->
        # Update email log status based on event
        update_log_status_from_event(email_log, event)
        {:ok, event}

      error ->
        error
    end
  end

  # Update email log status based on event type
  defp update_log_status_from_event(email_log, %PhoenixKit.Modules.Emails.Event{
         event_type: "delivery"
       }) do
    Log.mark_as_delivered(email_log)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.Modules.Emails.Event{
         event_type: "bounce",
         bounce_type: bounce_type
       }) do
    Log.mark_as_bounced(email_log, bounce_type)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.Modules.Emails.Event{
         event_type: "open"
       }) do
    Log.mark_as_opened(email_log)
  end

  defp update_log_status_from_event(email_log, %PhoenixKit.Modules.Emails.Event{
         event_type: "click",
         link_url: url
       }) do
    Log.mark_as_clicked(email_log, url)
  end

  defp update_log_status_from_event(_email_log, _event) do
    # No status update needed for other event types
    :ok
  end

  # Get compression setting
  defp get_compress_after_days do
    Settings.get_integer_setting("email_compress_body", 30)
  end

  # Check if S3 archival is enabled
  defp s3_archival_enabled? do
    Settings.get_boolean_setting("email_archive_to_s3", false)
  end

  # Get period start/end dates
  defp get_period_dates(:last_7_days) do
    end_date = UtilsDate.utc_now()
    start_date = DateTime.add(end_date, -7, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_30_days) do
    end_date = UtilsDate.utc_now()
    start_date = DateTime.add(end_date, -30, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_90_days) do
    end_date = UtilsDate.utc_now()
    start_date = DateTime.add(end_date, -90, :day)
    {start_date, end_date}
  end

  defp get_period_dates(:last_24_hours) do
    end_date = UtilsDate.utc_now()
    start_date = DateTime.add(end_date, -1, :day)
    {start_date, end_date}
  end

  defp get_period_dates({:date_range, start_date, end_date})
       when is_struct(start_date, Date) and is_struct(end_date, Date) do
    start_datetime = DateTime.new!(start_date, ~T[00:00:00])
    end_datetime = DateTime.new!(end_date, ~T[23:59:59])
    {start_datetime, end_datetime}
  end

  # Calculate safe percentage
  defp safe_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp safe_percentage(_, _), do: 0.0

  @doc """
  Checks if AWS credentials are configured, from any of the sources
  `get_aws_access_key/0`/`get_aws_secret_key/0` read (highest priority
  first): the selected `aws_ses` Integrations connection
  (`emails_aws_integration_uuid`), then the legacy `aws_access_key_id`/
  `aws_secret_access_key` Settings, then environment variables.
  """
  def aws_configured? do
    # get_aws_access_key/0 and get_aws_secret_key/0 return `nil` (not `""`)
    # when unconfigured — comparing against only `""` made this always
    # true (`nil != ""` is true), so it never actually reflected whether
    # AWS was configured.
    present?(get_aws_access_key()) and present?(get_aws_secret_key())
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Returns the email provider actually in effect, detected from the host
  app's mailer configuration (see `PhoenixKit.Modules.Emails.Utils.mailer_adapter_status/0`).

  Falls back to `"aws_ses"` when the adapter can't be statically detected
  (e.g. a delegated mailer configured at runtime) but AWS credentials are
  present — the same heuristic `Interceptor.detect_provider/2` already uses
  for delegation-mode hosts — otherwise `"unknown"`.

  ## Examples

      iex> PhoenixKit.Modules.Emails.current_provider()
      "aws_ses"
  """
  @spec current_provider() :: String.t()
  def current_provider do
    case Utils.mailer_adapter_status().provider do
      "unknown" -> if aws_configured?(), do: "aws_ses", else: "unknown"
      provider -> provider
    end
  end

  @doc """
  Gets AWS access key.

  Priority: selected Integrations connection → Settings Database →
  Environment Variables (see `aws_ses_credentials/0`).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_aws_access_key()
      "AKIA..."
  """
  def get_aws_access_key do
    Map.get(aws_ses_credentials(), "access_key") || legacy_aws_access_key()
  end

  defp legacy_aws_access_key do
    Settings.get_setting("aws_access_key_id")
    |> case do
      key when is_binary(key) and key != "" -> key
      _ -> AWS.access_key_id()
    end
  end

  @doc """
  Gets AWS secret key.

  Priority: selected Integrations connection → Settings Database →
  Environment Variables (see `aws_ses_credentials/0`).

  ## Examples

      iex> PhoenixKit.Modules.Emails.get_aws_secret_key()
      "secret..."
  """
  def get_aws_secret_key do
    Map.get(aws_ses_credentials(), "secret_key") || legacy_aws_secret_key()
  end

  defp legacy_aws_secret_key do
    Settings.get_setting("aws_secret_access_key")
    |> case do
      key when is_binary(key) and key != "" -> key
      _ -> AWS.secret_access_key()
    end
  end

  # Credentials from the `aws_ses` Integrations connection selected via
  # the `emails_aws_integration_uuid` setting, or an empty map when no
  # integration is selected / configured. `get_aws_*` getters merge this
  # over the legacy `aws_*` Settings fallback.
  #
  # Cached for @aws_credentials_cache_ttl_ms (60_000ms / 60s) via
  # `PhoenixKit.Cache` (same mechanism `Settings.get_setting_cached/2`
  # already uses, under its own `:emails_aws_credentials` instance) — every
  # `get_aws_*` getter used to call this independently, so building one
  # send-path config (`get_aws_config/0`) meant 3 separate
  # `Settings.get_setting/1` reads PLUS 3 separate
  # `Integrations.get_credentials/1` calls (a DB read + decrypt each) for
  # the SAME connection, on every single email sent. Now it's one combined
  # lookup, reused for the cache's TTL.
  # `invalidate_aws_credentials_cache/0` is called wherever the selected
  # integration changes, so switching connections doesn't wait out the TTL.
  # `PhoenixKit.Cache.get/put` gracefully no-op (cache miss / silent) when
  # the named instance isn't running — e.g. this package's own standalone
  # test suite, which never boots `PhoenixKit.Supervisor` — so this always
  # falls back to the real, uncached lookup there.
  defp aws_ses_credentials do
    cache_miss = :__aws_credentials_cache_miss__

    # Cached under the bare `:credentials` key, NOT `{:credentials, uuid}`:
    # the unit being memoized here is the whole legacy resolution, selection
    # lookup included, which is what keeps a send path from re-reading
    # `emails_aws_integration_uuid` once per `get_aws_*` getter.
    case PhoenixKit.Cache.get(@aws_credentials_cache_name, :credentials, cache_miss) do
      ^cache_miss ->
        creds =
          case selected_aws_integration_uuid() do
            uuid when is_binary(uuid) -> fetch_aws_ses_credentials(uuid)
            _ -> %{}
          end

        PhoenixKit.Cache.put(@aws_credentials_cache_name, :credentials, creds)
        creds

      creds ->
        creds
    end
  end

  @doc """
  The single `aws_ses` Integrations connection selected via the
  `emails_aws_integration_uuid` setting, or `nil`.

  This is the LEGACY, one-account selection: it names the connection the
  global `aws_*` settings (queue URL, configuration set, …) have always
  described, and it is still what the send-path `get_aws_*` getters resolve
  through. Multi-account callers should go through
  `PhoenixKit.Modules.Emails.AwsIntegrations.active_integration_uuids/0`
  instead; this getter exists so they can recognise which one account the
  legacy globals may still be attributed to.

  ## Examples

      iex> PhoenixKit.Modules.Emails.selected_aws_integration_uuid()
      "019f562e-0000-7000-8000-000000000000"
  """
  @spec selected_aws_integration_uuid() :: String.t() | nil
  def selected_aws_integration_uuid do
    case Settings.get_setting("emails_aws_integration_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  @doc """
  The decrypted credential map for ONE `aws_ses` Integrations connection,
  memoized under `{:credentials, uuid}`.

  Keyed by uuid rather than a single `:credentials` slot because the SQS
  poller now walks several accounts per cycle: a single-slot cache handed
  whichever account was resolved first to every subsequent lookup, which
  with two accounts means polling one account's queue with the other's
  keys. Cleared by `invalidate_aws_credentials_cache/0`, which every write
  site that can change a resolution already calls.

  ## Examples

      iex> PhoenixKit.Modules.Emails.aws_ses_credentials("some-uuid")
      %{"access_key" => "AKIA...", "secret_key" => "...", "aws_region" => "eu-north-1"}
  """
  @spec aws_ses_credentials(String.t()) :: map()
  def aws_ses_credentials(uuid) when is_binary(uuid) and uuid != "" do
    cache_miss = :__aws_credentials_cache_miss__
    key = {:credentials, uuid}

    case PhoenixKit.Cache.get(@aws_credentials_cache_name, key, cache_miss) do
      ^cache_miss ->
        creds = fetch_aws_ses_credentials(uuid)
        PhoenixKit.Cache.put(@aws_credentials_cache_name, key, creds)
        creds

      creds ->
        creds
    end
  end

  def aws_ses_credentials(_uuid), do: %{}

  @doc """
  The decrypted credential map for ONE S3-archival Integrations connection,
  memoized under `{:s3_archival_credentials, uuid}` (same cache table and
  invalidation as `aws_ses_credentials/1`, distinct key so the two never
  collide).

  Deliberately a separate function rather than widening `aws_ses_credentials/1`
  itself: that one backs the SEND path (`selected_aws_integration_uuid/0`,
  the mailer's access/secret/region getters, per-account SQS polling) and
  must stay `aws_ses`-only — an `object_storage` connection has no business
  signing outgoing mail. This one backs `Archiver.s3_request_config/0`
  instead, which needs credentials for uploading to S3, not for sending
  through it, so it accepts either provider shape: `aws_ses` (the connection
  an install may already have pointed archival at, before `object_storage`
  existed) or `object_storage` (the type built for this — see
  `object_storage` in core's `PhoenixKit.Integrations.Providers`).
  """
  @spec s3_archival_credentials(String.t()) :: map()
  def s3_archival_credentials(uuid) when is_binary(uuid) and uuid != "" do
    cache_miss = :__aws_credentials_cache_miss__
    key = {:s3_archival_credentials, uuid}

    case PhoenixKit.Cache.get(@aws_credentials_cache_name, key, cache_miss) do
      ^cache_miss ->
        creds = fetch_credentials_for_providers(uuid, ["aws_ses", "object_storage"])
        PhoenixKit.Cache.put(@aws_credentials_cache_name, key, creds)
        creds

      creds ->
        creds
    end
  end

  def s3_archival_credentials(_uuid), do: %{}

  defp fetch_aws_ses_credentials(uuid), do: fetch_credentials_for_providers(uuid, ["aws_ses"])

  # The provider check is not ceremony: both public callers above take any
  # uuid, `Integrations.get_credentials/2` defaults to `owner: :any`, and the
  # map it returns is DECRYPTED. Without this, passing a Brevo (or any other)
  # connection's uuid would hand back that connection's secrets through an
  # AWS-named function. `creds["provider"]` is already in the map core's own
  # mailer reads, so this costs nothing. `allowed_providers` is the caller's
  # own allowlist — `fetch_aws_ses_credentials/1` passes `["aws_ses"]`,
  # `s3_archival_credentials/1` passes `["aws_ses", "object_storage"]`.
  defp fetch_credentials_for_providers(uuid, allowed_providers) do
    case Integrations.get_credentials(uuid) do
      {:ok, %{"provider" => provider} = creds} ->
        if provider in allowed_providers, do: creds, else: %{}

      {:ok, creds} when is_map(creds) ->
        # A connection saved before `provider` was stored in the blob reads as
        # missing rather than wrong — accepted by ANY caller regardless of
        # its allowlist (the historical behaviour, when only `aws_ses`
        # existed and this branch's caller was the only caller) instead of
        # breaking those installs.
        creds

      _ ->
        %{}
    end
  end

  @doc false
  # The send path's account attribution, resolved once and memoized for the
  # same TTL as the credentials themselves.
  #
  # `Interceptor` needs three facts on EVERY outgoing email: which integration
  # the operator's default send path resolves to, what provider that connection
  # is (to refuse a mis-attribution), and whether it is the only active SES
  # account (which is what makes a per-account configuration set safe to put on
  # the wire — see `Interceptor.enrich_send_opts/1`). Uncached, that is a
  # Settings read, a credentials decrypt and a `list_send_profiles/0` query per
  # message, which a bulk send pays thousands of times.
  #
  # Returns `nil` when no default send integration is configured.
  #
  # Staleness window worth knowing: every input here belongs to CORE — the
  # `default_email_integration_uuid` setting and the connection behind it are
  # edited on core's own Integrations page, which has no hook into this
  # package. So after an operator switches the default account, sends keep the
  # previous uuid (and, where it applies, the previous account's configuration
  # set) for up to the cache TTL. Anything this package itself changes calls
  # `invalidate_aws_credentials_cache/0` and takes effect immediately; the
  # remaining window is the price of not paying three uncached lookups per
  # message, and it is bounded rather than indefinite.
  @spec default_send_attribution() ::
          %{
            uuid: String.t(),
            provider: String.t() | nil,
            single_ses_account?: boolean()
          }
          | nil
  def default_send_attribution do
    # WHICH account is read fresh on every send; only the expensive facts ABOUT
    # that account are memoized, under a key that includes it.
    #
    # Caching the uuid too meant an operator who switched the default account
    # kept sending under the previous one — with, where it applied, the
    # previous account's configuration set — for up to the cache TTL. Nothing
    # here could invalidate that: the setting lives on core's Integrations
    # page, which has no hook into this package. Reading it through
    # `get_setting_cached/2` costs an in-memory lookup and is never stale,
    # because core invalidates its own settings cache on write. A changed
    # default therefore lands on a different cache key and takes effect on the
    # next message.
    case Settings.get_setting_cached("default_email_integration_uuid") do
      uuid when is_binary(uuid) and uuid != "" -> send_attribution_for(uuid)
      _ -> nil
    end
  end

  defp send_attribution_for(uuid) do
    cache_miss = :__aws_credentials_cache_miss__
    key = {:send_attribution, uuid}

    case PhoenixKit.Cache.get(@aws_credentials_cache_name, key, cache_miss) do
      ^cache_miss ->
        attribution = fetch_default_send_attribution(uuid)
        PhoenixKit.Cache.put(@aws_credentials_cache_name, key, attribution)
        attribution

      attribution ->
        attribution
    end
  end

  defp fetch_default_send_attribution(uuid) do
    # Mirrors PhoenixKit.Mailer's own (private) default_send_integration_uuid/0,
    # including its `connected?/1` gate — the same mirror
    # `PhoenixKit.Modules.Emails.Status` already keeps for the status card.
    if Integrations.connected?(uuid) do
      provider =
        case Integrations.get_integration_by_uuid(uuid) do
          {:ok, %{provider: provider}} when is_binary(provider) and provider != "" -> provider
          _ -> nil
        end

      %{
        uuid: uuid,
        provider: provider,
        single_ses_account?: single_ses_account?(uuid)
      }
    end
  end

  # "There is no other SES account this send could have gone through."
  #
  # Counted over `aws_ses` CONNECTIONS, not just over the accounts an enabled
  # SendProfile points at. Core hands the interceptor only `:provider`, so a
  # send routed through a second `aws_ses` connection that has no SendProfile
  # at all is indistinguishable from one through the default — and a
  # profile-only count called that situation "single account", stamped the
  # default's configuration set onto a message signed with the other account's
  # keys, and earned a hard `ConfigurationSetDoesNotExist` from SES.
  #
  # Active profiles are still unioned in: a profile can outlive the connection
  # listing under a different owner scope, and either source alone is a way to
  # under-count.
  defp single_ses_account?(uuid) do
    connections =
      "aws_ses"
      |> Integrations.list_connections(owner: :any)
      |> Enum.map(& &1.uuid)

    MapSet.new(connections ++ AwsIntegrations.active_integration_uuids()) ==
      MapSet.new([uuid])
  end

  @doc false
  # The SES configuration set this account carries, memoized for the send path
  # (see `default_send_attribution/0` for why the caching exists at all).
  @spec account_configuration_set(String.t() | nil) :: String.t() | nil
  def account_configuration_set(uuid) when is_binary(uuid) and uuid != "" do
    cache_miss = :__aws_credentials_cache_miss__
    key = {:configuration_set, uuid}

    case PhoenixKit.Cache.get(@aws_credentials_cache_name, key, cache_miss) do
      ^cache_miss ->
        config_set =
          case get_aws_tracking(uuid) do
            %{configuration_set: config_set} -> config_set
            _ -> nil
          end

        PhoenixKit.Cache.put(@aws_credentials_cache_name, key, config_set)
        config_set

      config_set ->
        config_set
    end
  end

  def account_configuration_set(_uuid), do: nil

  @doc """
  Invalidates the cached AWS SES credential resolution (`aws_ses_credentials/0`).

  Call after anything that changes which credentials `get_aws_access_key/0`,
  `get_aws_secret_key/0`, or `get_aws_region/0` should resolve to — selecting
  a different `aws_ses` Integrations connection, clearing the selection back
  to legacy Settings, or updating the selected connection's own credentials.
  Without this, a switch would still take effect, just not sooner than the
  cache's #{@aws_credentials_cache_ttl_ms}ms TTL.
  """
  @spec invalidate_aws_credentials_cache() :: :ok
  def invalidate_aws_credentials_cache do
    # Deliberately a whole-instance clear rather than a per-key invalidation.
    # The instance now memoizes several derived things under different keys —
    # `:credentials`, `{:credentials, uuid}`, `:send_attribution`,
    # `{:configuration_set, uuid}` — and every caller of this function has
    # changed something that can invalidate MORE than one of them (selecting a
    # different connection changes the attribution AND the credentials; writing
    # an account's tracking row changes its configuration set AND, if it was
    # the only active account, the attribution). A targeted API would have to
    # be right about which, and being wrong is silent. The instance holds
    # nothing else and a repopulate is one read.
    PhoenixKit.Cache.clear(@aws_credentials_cache_name)
  end

  # Validate SQS queue URL format
  defp valid_queue_url?(queue_url) when is_binary(queue_url) do
    # Expected format: https://sqs.{region}.amazonaws.com/{account_id}/{queue_name}
    case Regex.run(
           ~r|^https://sqs\.([a-z0-9-]+)\.amazonaws\.com/(\d+)/([a-zA-Z0-9_-]+)$|,
           queue_url
         ) do
      [_full, _region, _account_id, _queue_name] -> true
      _ -> false
    end
  end

  defp valid_queue_url?(_), do: false
end
