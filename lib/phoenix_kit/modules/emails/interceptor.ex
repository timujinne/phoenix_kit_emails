defmodule PhoenixKit.Modules.Emails.Interceptor do
  @moduledoc """
  Email interceptor for logging outgoing emails in PhoenixKit.

  This module provides functionality to intercept outgoing emails and create
  comprehensive logs for tracking purposes. It integrates seamlessly with
  the existing mailer system without disrupting email delivery.

  ## Features

  - **Transparent Interception**: Logs emails without affecting delivery
  - **Selective Logging**: Respects sampling rate and system settings
  - **AWS SES Integration**: Automatically adds configuration sets
  - **Rich Metadata Extraction**: Captures headers, size, attachments
  - **User Context**: Links emails to users when possible
  - **Template Recognition**: Identifies email templates and campaigns

  ## Integration

  The interceptor is designed to be called by the mailer before sending:

      # In PhoenixKit.Mailer.deliver_email/1
      email = EmailInterceptor.intercept_before_send(email, opts)
      # ... then send email normally

  ## Configuration

  The interceptor respects all email tracking system settings:

  - Only logs if `email_enabled` is true
  - Saves body based on `email_save_body` setting
  - Applies sampling rate from `email_sampling_rate`
  - Adds AWS SES configuration set if configured

  ## Examples

      # Basic interception
      logged_email = PhoenixKit.Modules.Emails.Interceptor.intercept_before_send(email)

      # With additional context
      logged_email = PhoenixKit.Modules.Emails.Interceptor.intercept_before_send(email,
        user_uuid: "018f1234-5678-7890-abcd-ef1234567890",
        template_name: "welcome_email",
        campaign_id: "welcome_series"
      )

      # Check if email should be logged
      if PhoenixKit.Modules.Emails.Interceptor.should_log_email?(email) do
        # Log the email
      end
  """

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.EmailLogData
  alias PhoenixKit.Modules.Emails.Event
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias Swoosh.Email

  @doc """
  Intercepts an email before sending and creates a tracking log.

  Returns the email (potentially modified with tracking headers) and
  creates a log entry if tracking is enabled.

  ## Options

  - `:user_uuid` - Associate with a specific user
  - `:template_name` - Name of the email template
  - `:campaign_id` - Campaign identifier for grouping
  - `:provider` - Override provider detection
  - `:configuration_set` - Override AWS SES configuration set
  - `:message_tags` - Additional tags for the email

  ## Examples

      iex> email = new() |> to("user@example.com") |> from("app@example.com")
      iex> PhoenixKit.Modules.Emails.Interceptor.intercept_before_send(email, user_uuid: "018f1234-5678-7890-abcd-ef1234567890")
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "456"}}
  """
  def intercept_before_send(%Email{} = email, opts \\ []) do
    if Emails.enabled?() and should_log_email?(email, opts) do
      case create_email_log(email, opts) do
        {:ok, log} ->
          # Add tracking headers to email
          add_tracking_headers(email, log, opts)

        {:error, :skipped} ->
          email

        {:error, reason} ->
          Logger.error("Failed to log email: #{inspect(reason)}")
          email
      end
    else
      email
    end
  end

  @doc """
  Determines if an email should be logged based on system settings.

  Considers sampling rate, system enablement, and email characteristics.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.should_log_email?(email)
      true
  """
  def should_log_email?(%Email{} = email, _opts \\ []) do
    cond do
      not Emails.enabled?() ->
        false

      system_email?(email) ->
        # Always log system emails (errors, bounces, etc.)
        true

      true ->
        # Apply sampling rate for regular emails
        sampling_rate = Emails.get_sampling_rate()
        meets_sampling_threshold?(email, sampling_rate)
    end
  end

  @doc """
  Extracts provider information from email or mailer configuration.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.detect_provider(email, [])
      "aws_ses"
  """
  def detect_provider(%Email{} = email, opts \\ []) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        provider

      has_ses_headers?(email) ->
        "aws_ses"

      has_smtp_headers?(email) ->
        "smtp"

      # A configured SES configuration set is a strong indicator for AWS SES
      # (checked via settings), even when using a delegated mailer. We evaluate
      # it before the config fallback because at log-creation time the
      # X-SES-CONFIGURATION-SET header may not yet be present on the email.
      not is_nil(get_configuration_set(opts)) ->
        "aws_ses"

      true ->
        Utils.detect_provider_from_config()
    end
  end

  @doc """
  Creates an email log entry from a Swoosh.Email struct.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.create_email_log(email, user_uuid: "018f1234-5678-7890-abcd-ef1234567890")
      {:ok, %Log{}}
  """
  def create_email_log(%Email{} = email, opts \\ []) do
    log_attrs = extract_email_data(email, opts)

    Emails.create_log(log_attrs)
  end

  @doc """
  Adds tracking headers to an email for identification.

  ## Examples

      iex> email_with_headers = PhoenixKit.Modules.Emails.Interceptor.add_tracking_headers(email, log, [])
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "123"}}
  """
  def add_tracking_headers(%Email{} = email, %Log{} = log, opts \\ []) do
    tracking_headers = %{
      "X-PhoenixKit-Log-Id" => to_string(log.uuid),
      "X-PhoenixKit-Message-Id" => log.message_id
    }

    # Add AWS SES specific headers
    ses_headers = build_ses_headers(log, opts)

    all_headers = Map.merge(tracking_headers, ses_headers)

    # Add headers to email
    Enum.reduce(all_headers, email, fn {key, value}, acc_email ->
      Email.header(acc_email, key, value)
    end)
  end

  @doc """
  Builds AWS SES specific tracking headers and configuration.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.build_ses_headers(log, [])
      %{"X-SES-CONFIGURATION-SET" => "my-tracking-set"}
  """
  def build_ses_headers(%Log{} = log, opts \\ []) do
    headers = %{}

    # Add configuration set if available
    headers =
      case get_configuration_set(opts) do
        nil ->
          headers

        config_set ->
          Map.put(headers, "X-SES-CONFIGURATION-SET", config_set)
      end

    # Add message tags for AWS SES
    headers =
      case build_message_tags(log, opts) do
        tags when map_size(tags) > 0 ->
          # Convert tags to SES format
          tag_headers =
            Enum.with_index(tags, 1)
            |> Enum.reduce(headers, fn {{key, value}, index}, acc ->
              Map.put(acc, "X-SES-MESSAGE-TAG-#{index}", "#{key}=#{value}")
            end)

          tag_headers

        _ ->
          headers
      end

    headers
  end

  @doc """
  Updates an email log after successful sending.

  This is called after the email provider confirms the send.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.update_after_send(log, provider_response)
      {:ok, %Log{}}
  """
  def update_after_send(%Log{} = log, provider_response \\ %{}) do
    Logger.info("EmailInterceptor: Updating email log after send", %{
      log_uuid: log.uuid,
      current_message_id: log.message_id,
      response_keys:
        if(is_map(provider_response), do: Map.keys(provider_response), else: "not_map")
    })

    update_attrs = %{
      status: "sent",
      sent_at: UtilsDate.utc_now()
    }

    update_attrs = maybe_extract_provider_data(log, provider_response, update_attrs)

    case Log.update_log(log, update_attrs) do
      {:ok, updated_log} ->
        Logger.info("EmailInterceptor: Successfully updated email log", %{
          log_uuid: updated_log.uuid,
          internal_message_id: updated_log.message_id,
          aws_message_id: updated_log.aws_message_id,
          status: updated_log.status
        })

        # Create send event
        Event.create_send_event(updated_log.uuid, updated_log.provider)

        {:ok, updated_log}

      {:error, reason} ->
        Logger.error("EmailInterceptor: Failed to update email log", %{
          log_uuid: log.uuid,
          reason: inspect(reason),
          update_attrs: update_attrs
        })

        {:error, reason}
    end
  end

  @doc """
  Updates an email log after send failure.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Interceptor.update_after_failure(log, error)
      {:ok, %Log{}}
  """
  def update_after_failure(%Log{} = log, error) do
    error_message = extract_error_message(error)

    update_attrs = %{
      status: "failed",
      error_message: error_message,
      retry_count: log.retry_count + 1
    }

    Log.update_log(log, update_attrs)
  end

  ## --- Private Helper Functions ---

  # Only AWS SES returns a MessageId we can recover; for Test/Local/SMTP/etc.
  # the response carries no useful provider data and attempting extraction
  # produces noisy warnings on every send.
  defp maybe_extract_provider_data(
         %Log{provider: "aws_ses"} = log,
         provider_response,
         update_attrs
       ) do
    extraction_result = extract_provider_data(provider_response, log.uuid)

    case extraction_result do
      %{message_id: aws_message_id} when is_binary(aws_message_id) ->
        Logger.info("EmailInterceptor: Storing AWS message_id in aws_message_id field", %{
          log_uuid: log.uuid,
          internal_message_id: log.message_id,
          aws_message_id: aws_message_id
        })

        log_extraction_metric(true, log.uuid, aws_message_id)
        store_aws_message_id(log, aws_message_id, provider_response, update_attrs)

      %{} = provider_data when map_size(provider_data) > 0 ->
        log_extraction_metric(false, log.uuid, nil)

        updated_message_tags =
          Map.merge(log.message_tags || %{}, %{
            "internal_message_id" => log.message_id,
            "extraction_failed" => true,
            "provider_response_debug" => sanitize_provider_response(provider_response)
          })

        Map.merge(update_attrs, provider_data)
        |> Map.put(:message_tags, updated_message_tags)

      _ ->
        log_extraction_metric(false, log.uuid, nil)

        Logger.warning("EmailInterceptor: No provider data extracted", %{
          log_uuid: log.uuid,
          response: inspect(provider_response) |> String.slice(0, 300)
        })

        updated_message_tags =
          Map.merge(log.message_tags || %{}, %{
            "internal_message_id" => log.message_id,
            "extraction_failed" => true,
            "provider_response_debug" => sanitize_provider_response(provider_response)
          })

        Map.put(update_attrs, :message_tags, updated_message_tags)
    end
  end

  # Option-1 host-app mailers send through the app's OWN Swoosh AmazonSES mailer,
  # whose config lives under the app's otp_app — detect_provider_from_config
  # cannot read it, so detect_provider/2 returns "unknown". In that ONE case the
  # success response may still carry a real AWS MessageId we can recover. The
  # gate is deliberately narrow:
  #   - only provider == "unknown" (an explicitly-detected local/smtp/sendgrid/...
  #     provider is trusted as-is and never reclassified), and
  #   - only a value that looks like an AWS SES MessageId. Swoosh.Adapters.Local
  #     returns the email's RFC "<id@host>" header as :id; that is NOT a SES
  #     MessageId and must never reclassify a dev/test send to "aws_ses".
  # Extraction is SILENT (no failure warning) so non-SES sends produce no noise.
  defp maybe_extract_provider_data(
         %Log{provider: "unknown"} = log,
         provider_response,
         update_attrs
       ) do
    case extract_message_id_from_response(provider_response) do
      %{message_id: aws_message_id}
      when is_binary(aws_message_id) ->
        if aws_ses_message_id?(aws_message_id) do
          Logger.info("EmailInterceptor: Recovered AWS message_id for Option-1 mailer", %{
            log_uuid: log.uuid,
            aws_message_id: aws_message_id
          })

          log_extraction_metric(true, log.uuid, aws_message_id)

          update_attrs
          |> Map.put(:provider, "aws_ses")
          |> then(&store_aws_message_id(log, aws_message_id, provider_response, &1))
        else
          update_attrs
        end

      _ ->
        update_attrs
    end
  end

  # Brevo (Swoosh.Adapters.Brevo) returns its own message id the same way
  # SES does, just under a different key set — extract_provider_data/2
  # already handles all the shapes Swoosh adapters use (:id, "id",
  # "messageId", ...). Stored in the same `aws_message_id` field AWS SES
  # uses: despite the name, that field's actual purpose is "the id the
  # provider's own event/webhook API will report back", which is exactly
  # what BrevoPollingJob needs to correlate a polled event to this log —
  # find_email_log_by_message_id/1 already falls back to it generically.
  # No new column, no reclassification risk (unlike the "unknown" clause
  # above): provider is already definitively "brevo_api" here, set by
  # `deliver_via_integration/3`'s explicit :provider override.
  defp maybe_extract_provider_data(
         %Log{provider: "brevo_api"} = log,
         provider_response,
         update_attrs
       ) do
    case extract_provider_data(provider_response, log.uuid) do
      %{message_id: brevo_message_id} when is_binary(brevo_message_id) ->
        log_extraction_metric(true, log.uuid, brevo_message_id)
        store_aws_message_id(log, brevo_message_id, provider_response, update_attrs)

      _ ->
        log_extraction_metric(false, log.uuid, nil)
        update_attrs
    end
  end

  defp maybe_extract_provider_data(_log, _provider_response, update_attrs), do: update_attrs

  # AWS SES MessageIds are opaque tokens without RFC Message-ID punctuation. An id
  # containing "<", ">" or "@" is an RFC angle-bracket Message-ID (e.g. from the
  # Swoosh Local adapter), not a SES MessageId — reject it so we never reclassify
  # a non-SES send to "aws_ses" with an id no SQS/SNS event can correlate to.
  defp aws_ses_message_id?(id) when is_binary(id) do
    not String.contains?(id, ["<", ">", "@"])
  end

  # Persist a recovered AWS MessageId into the dedicated aws_message_id field
  # (the SQS/SNS poller correlates events on it) and mirror the internal/AWS ids
  # plus a sanitized provider response into message_tags for debugging. The
  # internal pk_ id stays in message_id for backward compatibility.
  defp store_aws_message_id(%Log{} = log, aws_message_id, provider_response, update_attrs) do
    updated_message_tags =
      Map.merge(log.message_tags || %{}, %{
        "internal_message_id" => log.message_id,
        "aws_message_id" => aws_message_id,
        "provider_response_debug" => sanitize_provider_response(provider_response)
      })

    update_attrs
    |> Map.put(:aws_message_id, aws_message_id)
    |> Map.put(:message_tags, updated_message_tags)
  end

  # Extract comprehensive data from Swoosh.Email
  defp extract_email_data(%Email{} = email, opts) do
    user_uuid = Keyword.get(opts, :user_uuid)

    # Resolve the SES configuration set once and reuse it for both provider
    # detection and the stored field — avoids a duplicate settings lookup (and
    # duplicate validation warnings) on the send path.
    configuration_set = get_configuration_set(opts)
    opts = Keyword.put(opts, :configuration_set, configuration_set)

    %EmailLogData{
      message_id: generate_message_id(email, opts),
      to: extract_primary_recipient(email.to),
      from: extract_sender(email.from),
      subject: email.subject || "(no subject)",
      headers: extract_headers(email, opts),
      body_preview: extract_body_preview(email),
      body_full: extract_body_full(email, opts),
      attachments_count: length(email.attachments || []),
      size_bytes: estimate_email_size(email),
      template_name: Keyword.get(opts, :template_name),
      locale: Keyword.get(opts, :locale, "en"),
      campaign_id: Keyword.get(opts, :campaign_id),
      user_uuid: user_uuid,
      provider: detect_provider(email, opts),
      configuration_set: configuration_set,
      message_tags: build_message_tags(email, opts)
    }
  end

  # Generate or extract message ID
  defp generate_message_id(%Email{} = email, opts) do
    # Try to extract from existing headers first
    existing_id =
      get_in(email.headers, ["Message-ID"]) ||
        get_in(email.headers, ["message-id"]) ||
        Keyword.get(opts, :message_id)

    case existing_id do
      nil -> "pk_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
      id -> String.trim(id, "<>")
    end
  end

  # Extract primary recipient email
  defp extract_primary_recipient([{_name, email} | _]), do: email
  defp extract_primary_recipient([email | _]) when is_binary(email), do: email
  defp extract_primary_recipient({_name, email}), do: email
  defp extract_primary_recipient(email) when is_binary(email), do: email
  defp extract_primary_recipient(_), do: "unknown@example.com"

  # Extract sender email
  defp extract_sender({_name, email}), do: email
  defp extract_sender(email) when is_binary(email), do: email
  defp extract_sender(_), do: "unknown@example.com"

  # Extract and clean headers
  defp extract_headers(%Email{headers: headers}, _opts) when is_map(headers) do
    # Remove sensitive headers and normalize
    headers
    |> Enum.reject(fn {key, _} ->
      key in ["Authorization", "Authentication-Results", "X-Password", "X-API-Key"]
    end)
    |> Enum.into(%{})
  end

  defp extract_headers(_, _opts), do: %{}

  # Extract body preview (first 500+ characters)
  defp extract_body_preview(%Email{} = email) do
    body = email.text_body || email.html_body || ""

    body
    |> strip_html_tags()
    # Increased from 500 to 1000 as per plan
    |> String.slice(0, 1000)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Extract full body if enabled
  defp extract_body_full(%Email{} = email, opts) do
    if Emails.save_body_enabled?() or Keyword.get(opts, :save_body, false) do
      text_body = email.text_body || ""
      html_body = email.html_body || ""

      if String.length(html_body) > String.length(text_body) do
        html_body
      else
        text_body
      end
    else
      nil
    end
  end

  # Estimate email size in bytes
  defp estimate_email_size(%Email{} = email) do
    size = 0

    # Headers
    size = size + (email.headers |> inspect() |> byte_size())

    # Subject
    size = size + byte_size(email.subject || "")

    # Body
    size = size + byte_size(email.text_body || "")
    size = size + byte_size(email.html_body || "")

    # Attachments (rough estimate)
    attachment_size =
      (email.attachments || [])
      |> Enum.reduce(0, fn attachment, acc ->
        case attachment do
          %{data: data} when is_binary(data) ->
            acc + byte_size(data)

          %{path: path} when is_binary(path) ->
            case File.stat(path) do
              {:ok, %File.Stat{size: file_size}} -> acc + file_size
              # Default estimate
              _ -> acc + 10_000
            end

          # Default estimate
          _ ->
            acc + 10_000
        end
      end)

    size + attachment_size
  end

  # Check if email should be sampled
  defp meets_sampling_threshold?(%Email{} = email, sampling_rate) do
    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on recipient email
      recipient = extract_primary_recipient(email.to)
      hash = :erlang.phash2(recipient, 100)
      hash < sampling_rate
    end
  end

  # Check if this is a system/critical email
  defp system_email?(%Email{} = email) do
    subject = String.downcase(email.subject || "")
    sender = String.downcase(extract_sender(email.from))

    # System emails are always logged
    String.contains?(subject, ["error", "bounce", "failure", "alert", "warning", "critical"]) or
      String.contains?(sender, ["noreply", "no-reply", "system", "admin", "alert"])
  end

  # Get AWS SES configuration set
  defp get_configuration_set(opts) do
    config_set =
      Keyword.get(opts, :configuration_set) ||
        Emails.get_ses_configuration_set()

    # Only return config set if it's properly configured and not empty
    result =
      case config_set do
        nil ->
          nil

        "" ->
          nil

        "phoenixkit-tracking" ->
          # Default hardcoded value - only use if explicitly confirmed to exist
          if validate_ses_configuration_set("phoenixkit-tracking") do
            "phoenixkit-tracking"
          else
            Logger.warning("phoenixkit-tracking configuration set validation failed")
            nil
          end

        other when is_binary(other) ->
          # Custom config set - validate before using
          if validate_ses_configuration_set(other) do
            other
          else
            Logger.warning("Custom configuration set validation failed: #{other}")
            nil
          end

        _ ->
          Logger.warning("Invalid configuration set type: #{inspect(config_set)}")
          nil
      end

    result
  end

  # Validate that SES configuration set exists
  defp validate_ses_configuration_set(config_set) when is_binary(config_set) do
    # Enable configuration set if it's configured via settings
    # The AWS setup script ensures proper configuration exists
    config_set != ""
  end

  # Build message tags for categorization
  defp build_message_tags(%Email{} = email, opts) do
    base_tags = Keyword.get(opts, :message_tags, %{})

    auto_tags =
      %{}
      |> maybe_add_tag("template", Keyword.get(opts, :template_name))
      |> maybe_add_tag("campaign", Keyword.get(opts, :campaign_id))
      |> maybe_add_user_uuid(Keyword.get(opts, :user_uuid))
      |> maybe_add_tag("category", Keyword.get(opts, :category))
      |> maybe_add_tag("source_module", Keyword.get(opts, :source_module))
      |> add_email_type(email, opts)

    Map.merge(auto_tags, base_tags)
  end

  # Build message tags for log record (fallback clause)
  defp build_message_tags(_log_or_email, opts) do
    build_message_tags(%Email{}, opts)
  end

  # Add tag to map if value is not nil
  defp maybe_add_tag(tags, _key, nil), do: tags
  defp maybe_add_tag(tags, key, value), do: Map.put(tags, key, value)

  # Add user_uuid tag
  defp maybe_add_user_uuid(tags, nil), do: tags
  defp maybe_add_user_uuid(tags, user_uuid), do: Map.put(tags, "user_uuid", user_uuid)

  # Add email type - use template category if available, otherwise detect from content
  defp add_email_type(tags, email, opts) do
    email_type =
      case Keyword.get(opts, :category) do
        nil -> detect_email_type(email)
        category -> category
      end

    Map.put(tags, "email_type", email_type)
  end

  # Detect email type from content
  defp detect_email_type(%Email{} = email) do
    subject = String.downcase(email.subject || "")

    cond do
      String.contains?(subject, ["welcome", "confirm", "verify", "activate"]) -> "authentication"
      String.contains?(subject, ["reset", "password", "forgot"]) -> "password_reset"
      String.contains?(subject, ["newsletter", "update", "news"]) -> "newsletter"
      String.contains?(subject, ["invoice", "receipt", "payment", "billing"]) -> "transactional"
      String.contains?(subject, ["invitation", "invite"]) -> "invitation"
      true -> "general"
    end
  end

  # Check for SES specific headers
  defp has_ses_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SES-CONFIGURATION-SET") or
      Enum.any?(headers, fn {key, _} -> String.starts_with?(key, "X-SES-") end)
  end

  defp has_ses_headers?(_), do: false

  # Check for SMTP headers
  defp has_smtp_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SMTP-Server") or
      Map.has_key?(headers, "Received")
  end

  defp has_smtp_headers?(_), do: false

  # Extract data from provider response
  defp extract_provider_data(%{} = response, log_uuid) do
    # Extract message ID from various response formats
    extracted_data = extract_message_id_from_response(response)

    if Map.has_key?(extracted_data, :message_id) do
      Logger.info("EmailInterceptor: Successfully extracted AWS MessageId", %{
        log_uuid: log_uuid,
        message_id: extracted_data.message_id,
        response_format: detect_response_format(response),
        found_in_key: find_message_id_key(response)
      })
    else
      # Enhanced warning with more details for troubleshooting
      Logger.warning("EmailInterceptor: Failed to extract AWS MessageId", %{
        log_uuid: log_uuid,
        response_keys: Map.keys(response),
        response_structure: inspect_response_structure(response),
        response_sample: inspect(response) |> String.slice(0, 500),
        checked_formats: [
          "direct: :id, \"id\", \"MessageId\", \"messageId\", :message_id",
          "nested: body.id, body.MessageId",
          "aws_soap: SendEmailResponse.SendEmailResult.MessageId"
        ],
        recommendation:
          "Check if Swoosh adapter format changed. Full response saved in message_tags.provider_response_debug"
      })
    end

    extracted_data
  end

  defp extract_provider_data(_, _log_uuid), do: %{}

  # Extract message ID from different response formats
  defp extract_message_id_from_response(response) when is_map(response) do
    extract_direct_message_id(response) ||
      extract_nested_message_id(response) ||
      extract_ses_response_message_id(response) ||
      %{}
  end

  defp extract_message_id_from_response(_), do: %{}

  # Extract message ID from direct keys
  defp extract_direct_message_id(response) do
    cond do
      # Swoosh AmazonSES adapter returns {:ok, %{id: "message-id"}}
      Map.has_key?(response, :id) -> %{message_id: response[:id]}
      Map.has_key?(response, "id") -> %{message_id: response["id"]}
      # AWS API direct response formats
      Map.has_key?(response, "MessageId") -> %{message_id: response["MessageId"]}
      Map.has_key?(response, "messageId") -> %{message_id: response["messageId"]}
      Map.has_key?(response, :message_id) -> %{message_id: response[:message_id]}
      true -> nil
    end
  end

  # Extract message ID from nested body formats
  defp extract_nested_message_id(response) do
    cond do
      Map.has_key?(response, :body) and is_map(response.body) ->
        extract_message_id_from_response(response.body)

      Map.has_key?(response, "body") and is_map(response["body"]) ->
        extract_message_id_from_response(response["body"])

      true ->
        nil
    end
  end

  # Extract message ID from AWS SES SendEmailResponse structure
  defp extract_ses_response_message_id(response) do
    with true <- Map.has_key?(response, "SendEmailResponse"),
         send_response when is_map(send_response) <- response["SendEmailResponse"],
         true <- Map.has_key?(send_response, "SendEmailResult"),
         result when is_map(result) <- send_response["SendEmailResult"],
         true <- Map.has_key?(result, "MessageId") do
      %{message_id: result["MessageId"]}
    else
      _ -> nil
    end
  end

  # Detect response format for logging
  defp detect_response_format(response) when is_map(response) do
    cond do
      Map.has_key?(response, "MessageId") -> "direct_MessageId"
      Map.has_key?(response, "messageId") -> "direct_messageId"
      Map.has_key?(response, :message_id) -> "atom_message_id"
      Map.has_key?(response, :body) -> "nested_body"
      Map.has_key?(response, "SendEmailResponse") -> "aws_soap_format"
      true -> "unknown_format"
    end
  end

  # Extract error message from various error formats
  defp extract_error_message({:error, reason}) when is_binary(reason), do: reason
  defp extract_error_message({:error, reason}) when is_atom(reason), do: to_string(reason)
  defp extract_error_message({:error, %{message: message}}) when is_binary(message), do: message
  defp extract_error_message(%{message: message}) when is_binary(message), do: message
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(error) when is_atom(error), do: to_string(error)
  defp extract_error_message(error), do: inspect(error)

  # Strip HTML tags from text (basic)
  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&[a-zA-Z0-9#]+;/, " ")
  end

  defp strip_html_tags(_), do: ""

  # Helper function to identify which key contained the message ID
  defp find_message_id_key(response) do
    cond do
      Map.has_key?(response, :id) -> ":id (Swoosh format)"
      Map.has_key?(response, "id") -> "\"id\" (string format)"
      Map.has_key?(response, "MessageId") -> "\"MessageId\" (AWS API format)"
      Map.has_key?(response, "messageId") -> "\"messageId\" (camelCase format)"
      Map.has_key?(response, :message_id) -> ":message_id (atom snake_case format)"
      true -> "not_found"
    end
  end

  # Log extraction metric for monitoring
  defp log_extraction_metric(success?, log_uuid, aws_message_id) do
    metric_data = %{
      metric: "aws_message_id_extraction_rate",
      success: success?,
      log_uuid: log_uuid,
      aws_message_id: aws_message_id,
      timestamp: UtilsDate.utc_now()
    }

    if success? do
      Logger.info("EmailInterceptor Metric: AWS message_id extraction succeeded", metric_data)
    else
      Logger.warning("EmailInterceptor Metric: AWS message_id extraction failed", metric_data)
    end

    # Return metric for potential future use (e.g., sending to monitoring service)
    metric_data
  end

  # Sanitize provider response for safe storage
  defp sanitize_provider_response(response) when is_map(response) do
    # Limit response size to prevent bloating database
    # Keep only essential fields for debugging
    response
    |> inspect(limit: 1000, printable_limit: 1000)
    |> String.slice(0, 2000)
  end

  defp sanitize_provider_response(response) do
    inspect(response) |> String.slice(0, 2000)
  end

  # Inspect response structure for detailed logging
  defp inspect_response_structure(response) do
    %{
      top_level_keys: Map.keys(response),
      has_body: Map.has_key?(response, :body) or Map.has_key?(response, "body"),
      body_keys:
        cond do
          Map.has_key?(response, :body) and is_map(response.body) ->
            Map.keys(response.body)

          Map.has_key?(response, "body") and is_map(response["body"]) ->
            Map.keys(response["body"])

          true ->
            []
        end,
      has_nested_response:
        Map.has_key?(response, "SendEmailResponse") or Map.has_key?(response, :response) or
          Map.has_key?(response, "response"),
      value_types:
        response
        |> Enum.take(10)
        |> Enum.map(fn {k, v} -> {k, type_of(v)} end)
        |> Map.new()
    }
  end

  # Helper to get type of value
  defp type_of(value) when is_map(value), do: "map"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(_), do: "other"
end
