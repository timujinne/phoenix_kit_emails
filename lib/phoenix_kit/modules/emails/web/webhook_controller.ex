defmodule PhoenixKit.Modules.Emails.Web.WebhookController do
  @compile {:no_warn_undefined, [PhoenixKit.Users.RateLimiter.Backend]}
  @moduledoc """
  Secure webhook controller for AWS SNS email events.

  Handles incoming webhook notifications from AWS Simple Notification Service (SNS)
  for email events like bounces, complaints, deliveries, opens, and clicks.

  ## Security Features

  - **SNS Signature Verification**: Validates authentic AWS requests
  - **IP Whitelist**: Restricts access to AWS IP ranges
  - **Rate Limiting**: Prevents abuse with configurable limits
  - **Replay Attack Protection**: Timestamp verification (max 5 minutes)
  - **Request Size Limits**: Prevents oversized payloads
  - **Automatic Subscription Confirmation**: Handles SNS subscription setup

  ## Supported Event Types

  All 10 AWS SES email event types are supported:

  - **Send**: Email accepted by AWS SES for sending
  - **Reject**: Email rejected before sending (virus, content policy violation)
  - **Bounce**: Hard and soft bounces with detailed reasons
  - **Complaint**: Spam complaints and feedback loops
  - **Delivery**: Successful delivery confirmations
  - **Open**: Email open detection (AWS SES tracking pixel)
  - **Click**: Link click tracking in emails
  - **Rendering Failure**: Email template rendering errors
  - **Delivery Delay**: Temporary delivery delays
  - **Subscription**: Subscription preference updates or unsubscribes

  ## Configuration

  Security settings are stored in the database and managed via Settings:

      # Settings keys (all default to true)
      webhook_verify_sns_signature    # Validate AWS SNS signatures
      webhook_check_aws_ip            # Restrict to AWS IP ranges
      webhook_rate_limit_enabled      # Enable rate limiting

  Configure via Admin UI at `/admin/settings` or programmatically:

      PhoenixKit.Settings.update_boolean_setting("webhook_verify_sns_signature", false)

  ## Usage

  Add to your router:

      # Public webhook endpoint (no authentication)
      post "{prefix}/webhooks/email", PhoenixKitWeb.Controllers.EmailWebhookController, :handle

      # Note: {prefix} is your configured PhoenixKit URL prefix (default: /phoenix_kit)

  ## AWS SNS Setup

  1. Create SNS topic for SES events
  2. Subscribe this endpoint to the topic
  3. Configure SES to publish events to the topic
  4. The controller will automatically confirm subscriptions

  ## Example Webhook Payload

      %{
        "Type" => "Notification",
        "Message" => Jason.encode!(%{
          "eventType" => "bounce",
          "mail" => %{"messageId" => "abc123"},
          "bounce" => %{
            "bounceType" => "Permanent", 
            "bouncedRecipients" => [%{"emailAddress" => "user@example.com"}]
          }
        })
      }
  """

  use PhoenixKitWeb, :controller
  import Bitwise

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.RateLimiter.Backend, as: RateLimiterBackend
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Rate limiting: max 100 requests per 60 seconds per IP
  @rate_limit_max 100
  @rate_limit_window_ms :timer.seconds(60)
  # 5 minutes
  @max_request_age_seconds 300
  # 50KB
  @max_payload_size 50_000

  # AWS IP ranges for SNS (these should be updated periodically)
  @aws_sns_ip_ranges [
    # US East (N. Virginia)
    "54.240.217.0/24",
    "54.240.218.0/23",
    "54.240.220.0/22",
    # EU (Ireland)
    "176.34.159.192/26",
    "176.34.185.0/24",
    # Asia Pacific (Sydney)
    "54.240.197.0/24",
    "54.240.198.0/24"
  ]

  ## --- Main Handler ---

  @doc """
  Main webhook handler for AWS SNS notifications.

  Processes all incoming webhook requests with full security validation.
  """
  def handle(conn, params) do
    start_time = System.monotonic_time(:microsecond)

    with :ok <- check_request_size(conn),
         :ok <- check_rate_limit(conn),
         :ok <- verify_aws_ip(conn),
         :ok <- verify_request_age(params),
         {:ok, sns_message} <- parse_sns_message(params),
         :ok <- verify_sns_signature(sns_message),
         {:ok, result} <- process_sns_message(sns_message) do
      # Log successful processing
      processing_time = System.monotonic_time(:microsecond) - start_time

      Logger.info("Webhook processed successfully", %{
        message_type: sns_message["Type"],
        processing_time_ms: div(processing_time, 1000),
        result: result
      })

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "OK")
    else
      {:error, :rate_limited} ->
        Logger.warning("Webhook rejected: rate limited", %{
          remote_ip: get_remote_ip(conn)
        })

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too Many Requests")

      {:error, :request_too_large} ->
        Logger.warning("Webhook rejected: request too large")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(413, "Request Entity Too Large")

      {:error, :invalid_aws_ip} ->
        Logger.warning("Webhook rejected: invalid AWS IP", %{
          remote_ip: get_remote_ip(conn)
        })

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Forbidden")

      {:error, :request_too_old} ->
        Logger.warning("Webhook rejected: request too old")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Request Too Old")

      {:error, :invalid_signature} ->
        Logger.warning("Webhook rejected: invalid SNS signature")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Invalid Signature")

      {:error, reason} ->
        Logger.error("Webhook processing failed", %{
          reason: inspect(reason),
          remote_ip: get_remote_ip(conn)
        })

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Bad Request")
    end
  end

  ## --- Security Functions ---

  # Check request payload size
  defp check_request_size(conn) do
    content_length =
      case Plug.Conn.get_req_header(conn, "content-length") do
        [length_str] ->
          case Integer.parse(length_str) do
            {length, _} -> length
            _ -> 0
          end

        _ ->
          0
      end

    if content_length <= @max_payload_size do
      :ok
    else
      {:error, :request_too_large}
    end
  end

  # Check rate limiting per IP
  defp check_rate_limit(conn) do
    if rate_limiting_enabled?() do
      remote_ip = get_remote_ip(conn)
      check_ip_rate_limit(remote_ip)
    else
      :ok
    end
  end

  # Verify request comes from AWS IP ranges
  defp verify_aws_ip(conn) do
    if aws_ip_check_enabled?() do
      remote_ip = get_remote_ip(conn)

      if ip_in_aws_ranges?(remote_ip) do
        :ok
      else
        {:error, :invalid_aws_ip}
      end
    else
      :ok
    end
  end

  # Verify request timestamp is recent
  defp verify_request_age(params) do
    timestamp = params["Timestamp"] || params["timestamp"]

    case timestamp do
      nil ->
        {:error, :missing_timestamp}

      timestamp_str ->
        case parse_timestamp(timestamp_str) do
          {:ok, request_time} ->
            age_seconds = DateTime.diff(UtilsDate.utc_now(), request_time, :second)

            if age_seconds <= @max_request_age_seconds do
              :ok
            else
              {:error, :request_too_old}
            end

          {:error, _} ->
            {:error, :invalid_timestamp}
        end
    end
  end

  # Parse and validate SNS message structure
  defp parse_sns_message(params) do
    required_fields = ["Type"]

    if Enum.all?(required_fields, &Map.has_key?(params, &1)) do
      {:ok, params}
    else
      {:error, :invalid_sns_message}
    end
  end

  # Verify SNS message signature
  defp verify_sns_signature(sns_message) do
    if signature_verification_enabled?() do
      case verify_aws_sns_signature(sns_message) do
        :ok -> :ok
        :error -> {:error, :invalid_signature}
      end
    else
      :ok
    end
  end

  ## --- Message Processing ---

  # Process different types of SNS messages
  defp process_sns_message(%{"Type" => "SubscriptionConfirmation"} = message) do
    # Automatically confirm SNS subscription
    confirm_subscription(message)
  end

  defp process_sns_message(%{"Type" => "UnsubscribeConfirmation"} = message) do
    # Log unsubscription
    Logger.info("SNS topic unsubscribed", %{
      topic_arn: message["TopicArn"],
      subscription_arn: message["SubscriptionArn"]
    })

    {:ok, :unsubscribed}
  end

  defp process_sns_message(%{"Type" => "Notification"} = message) do
    # Process email event notification
    process_email_event_notification(message)
  end

  defp process_sns_message(%{"Type" => type}) do
    Logger.warning("Unknown SNS message type", %{type: type})
    {:ok, :unknown_type}
  end

  # Automatically confirm SNS subscription by issuing the GET to SubscribeURL.
  # The URL host is validated the same way as the signing cert URL to avoid SSRF.
  defp confirm_subscription(%{"SubscribeURL" => subscribe_url}) do
    Logger.info("SNS subscription confirmation requested", %{
      subscribe_url: subscribe_url
    })

    with :ok <- validate_aws_sns_url(subscribe_url),
         {:ok, status} <- http_get_status(subscribe_url) do
      if status == 200 do
        Logger.info("SNS subscription confirmed")
        {:ok, :subscription_confirmed}
      else
        Logger.error("Failed to confirm SNS subscription", %{status_code: status})
        {:error, :confirmation_failed}
      end
    else
      :error ->
        Logger.error("Invalid SNS SubscribeURL", %{subscribe_url: subscribe_url})
        {:error, :invalid_subscribe_url}

      {:error, reason} ->
        Logger.error("HTTP error confirming SNS subscription", %{reason: inspect(reason)})
        {:error, :http_error}
    end
  end

  defp confirm_subscription(_message) do
    {:error, :missing_subscribe_url}
  end

  # Process email event notification
  defp process_email_event_notification(%{"Message" => message_json}) do
    case Jason.decode(message_json) do
      {:ok, event_data} ->
        process_email_event(event_data)

      {:error, reason} ->
        Logger.error("Failed to parse SNS message JSON", %{
          reason: inspect(reason),
          message: String.slice(message_json, 0, 200)
        })

        {:error, :invalid_json}
    end
  end

  defp process_email_event_notification(_message) do
    {:error, :missing_message}
  end

  # Process individual email event
  defp process_email_event(event_data) do
    if Emails.enabled?() and Emails.ses_events_enabled?() do
      case Emails.process_webhook_event(event_data) do
        {:ok, :skipped} ->
          {:ok, :event_skipped}

        {:ok, event} ->
          Logger.info("Email webhook event processed successfully", %{
            event_type: event_data["eventType"],
            message_id: get_in(event_data, ["mail", "messageId"]),
            event_id: event.uuid,
            recipient: get_in(event_data, ["mail", "commonHeaders", "to"]) |> List.first()
          })

          {:ok, :event_processed}

        {:error, :message_id_not_found} ->
          Logger.warning("Email log not found for webhook event", %{
            event_type: event_data["eventType"],
            message_id: get_in(event_data, ["mail", "messageId"]),
            available_mail_fields: Map.keys(event_data["mail"] || %{}),
            timestamp: event_data["timestamp"]
          })

          {:ok, :log_not_found}

        {:error, :email_log_not_found} ->
          Logger.warning("Email log not found in database for webhook event", %{
            event_type: event_data["eventType"],
            message_id: get_in(event_data, ["mail", "messageId"]),
            suggestion: "Check if email was logged with a different message_id format"
          })

          {:ok, :log_not_found}

        {:error, reason} ->
          Logger.error("Failed to process email event", %{
            reason: inspect(reason),
            event_type: event_data["eventType"]
          })

          {:error, :processing_failed}
      end
    else
      Logger.debug("Email system disabled, skipping event")
      {:ok, :tracking_disabled}
    end
  end

  ## --- Helper Functions ---

  # Get remote IP address from connection.
  #
  # X-Forwarded-For is honored ONLY when the immediate peer (conn.remote_ip) is a
  # configured trusted proxy; otherwise the header is client-controlled and is
  # ignored in favour of conn.remote_ip. When honored, we walk the forwarded chain
  # from right to left and return the right-most hop that is NOT itself a trusted
  # proxy, since left-most entries can be forged by the original client.
  defp get_remote_ip(conn) do
    peer_ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    with true <- peer_ip in trusted_proxies(),
         [forwarded_ips] <- Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      forwarded_ips
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reverse()
      |> Enum.find(peer_ip, &(&1 not in trusted_proxies()))
    else
      _ -> peer_ip
    end
  end

  # Trusted reverse-proxy IPs allowed to set X-Forwarded-For.
  # Defaults to an empty list, in which case the header is never trusted.
  defp trusted_proxies do
    case Settings.get_setting("webhook_trusted_proxies", "") do
      value when is_binary(value) ->
        value
        |> String.split([",", " "], trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # Check if IP is in AWS SNS ranges
  defp ip_in_aws_ranges?(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} ->
        Enum.any?(@aws_sns_ip_ranges, fn range ->
          ip_in_cidr_range?(ip_tuple, range)
        end)

      {:error, _} ->
        false
    end
  end

  # Check if IP is in CIDR range
  defp ip_in_cidr_range?(ip_tuple, cidr_range) when is_binary(cidr_range) do
    case String.split(cidr_range, "/") do
      [network_str, prefix_len_str] ->
        case {
          :inet.parse_address(String.to_charlist(network_str)),
          Integer.parse(prefix_len_str)
        } do
          {{:ok, network_tuple}, {prefix_len, _}} ->
            ip_in_cidr_range?(ip_tuple, network_tuple, prefix_len)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # Actual CIDR range check
  defp ip_in_cidr_range?({a, b, c, d}, {na, nb, nc, nd}, prefix_len) when prefix_len <= 32 do
    ip_int = (a <<< 24) + (b <<< 16) + (c <<< 8) + d
    network_int = (na <<< 24) + (nb <<< 16) + (nc <<< 8) + nd

    mask = bnot((1 <<< (32 - prefix_len)) - 1)

    (ip_int &&& mask) == (network_int &&& mask)
  end

  defp ip_in_cidr_range?(_, _, _), do: false

  defp check_ip_rate_limit(ip) do
    key = "webhook:#{ip}"

    case RateLimiterBackend.hit(key, @rate_limit_window_ms, @rate_limit_max) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  # Parse ISO8601 timestamp
  defp parse_timestamp(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  # Verify AWS SNS message signature per:
  # https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html
  defp verify_aws_sns_signature(sns_message) do
    with {:ok, signature} <- fetch_field(sns_message, "Signature"),
         {:ok, cert_url} <- fetch_field(sns_message, "SigningCertURL"),
         {:ok, digest} <- signature_digest(sns_message),
         :ok <- validate_cert_url(cert_url),
         {:ok, cert_pem} <- fetch_certificate(cert_url),
         {:ok, public_key} <- extract_public_key(cert_pem),
         signing_string <- build_signing_string(sns_message),
         {:ok, decoded_sig} <- Base.decode64(signature) |> wrap_decode_result(),
         true <- :public_key.verify(signing_string, digest, decoded_sig, public_key) do
      :ok
    else
      _ -> :error
    end
  end

  # Map SNS SignatureVersion to the hash algorithm. Version "1" uses SHA-1,
  # version "2" uses SHA-256. Unknown/missing versions are rejected.
  defp signature_digest(sns_message) do
    case sns_message["SignatureVersion"] do
      "1" -> {:ok, :sha}
      "2" -> {:ok, :sha256}
      _ -> :error
    end
  end

  defp fetch_field(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  # Host pattern for AWS SNS endpoints: sns.<region>.amazonaws.com
  @sns_host_regex ~r/^sns\.[a-z0-9-]+\.amazonaws\.com$/

  # Validate the signing certificate URL before any network fetch. Requires https,
  # an exact sns.<region>.amazonaws.com host, and a SimpleNotificationService PEM
  # path. This blocks SSRF and signature forgery via attacker-hosted certs on
  # arbitrary *.amazonaws.com origins (e.g. public S3 buckets).
  defp validate_cert_url(url) do
    uri = URI.parse(url)
    path = uri.path || ""

    pem_path? =
      String.starts_with?(path, "/SimpleNotificationService-") and
        String.ends_with?(path, ".pem")

    if sns_host?(uri) and pem_path?, do: :ok, else: :error
  end

  # Validate the SubscribeURL before issuing the confirmation GET. Same host/scheme
  # rules as the cert URL (the path differs for SubscribeURL, so it is not checked).
  defp validate_aws_sns_url(url) do
    uri = URI.parse(url)
    if sns_host?(uri), do: :ok, else: :error
  end

  defp sns_host?(%URI{scheme: "https", host: host}) when is_binary(host) do
    Regex.match?(@sns_host_regex, host)
  end

  defp sns_host?(_uri), do: false

  # Fetch the PEM certificate from AWS (with simple in-memory cache via persistent_term)
  defp fetch_certificate(cert_url) do
    cache_key = {:sns_cert_cache, cert_url}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        case fetch_certificate_http(cert_url) do
          {:ok, pem} ->
            :persistent_term.put(cache_key, pem)
            {:ok, pem}

          error ->
            error
        end

      pem ->
        {:ok, pem}
    end
  end

  defp fetch_certificate_http(cert_url) do
    # Use Erlang's built-in :httpc (started with :inets)
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(cert_url), []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, List.to_string(body)}

      _ ->
        :error
    end
  end

  # Issue a GET (reusing the :httpc pattern) and return the HTTP status code.
  defp http_get_status(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 10_000}], []) do
      {:ok, {{_, status, _}, _headers, _body}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_public_key(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, _} | _] ->
        otp_cert = :public_key.pkix_decode_cert(der, :otp)
        # OTPCertificate -> tbsCertificate -> subjectPublicKeyInfo -> subjectPublicKey
        tbs = elem(otp_cert, 2)
        spki = elem(tbs, 8)
        {:ok, elem(spki, 2)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  # Build the string-to-sign per AWS SNS specification.
  # The fields and order depend on the message type.
  defp build_signing_string(%{"Type" => type} = msg) do
    fields =
      case type do
        "Notification" ->
          [
            {"Message", msg["Message"]},
            {"MessageId", msg["MessageId"]},
            {"Subject", msg["Subject"]},
            {"Timestamp", msg["Timestamp"]},
            {"TopicArn", msg["TopicArn"]},
            {"Type", type}
          ]

        _ ->
          # SubscriptionConfirmation / UnsubscribeConfirmation
          [
            {"Message", msg["Message"]},
            {"MessageId", msg["MessageId"]},
            {"SubscribeURL", msg["SubscribeURL"]},
            {"Timestamp", msg["Timestamp"]},
            {"Token", msg["Token"]},
            {"TopicArn", msg["TopicArn"]},
            {"Type", type}
          ]
      end

    fields
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join("", fn {k, v} -> "#{k}\n#{v}\n" end)
  end

  defp wrap_decode_result(:error), do: :error
  defp wrap_decode_result({:ok, _} = ok), do: ok

  # Configuration helpers - uses Settings database for centralized configuration
  defp signature_verification_enabled? do
    Settings.get_boolean_setting("webhook_verify_sns_signature", true)
  end

  defp aws_ip_check_enabled? do
    Settings.get_boolean_setting("webhook_check_aws_ip", true)
  end

  defp rate_limiting_enabled? do
    Settings.get_boolean_setting("webhook_rate_limit_enabled", true)
  end
end
