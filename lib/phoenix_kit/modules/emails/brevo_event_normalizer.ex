defmodule PhoenixKit.Modules.Emails.BrevoEventNormalizer do
  @moduledoc """
  Normalizes a single event from Brevo's `GET /v3/smtp/statistics/events`
  response into the same event-data shape `SQSProcessor.process_email_event/1`
  already accepts for AWS SES — see that function's `@doc` for the exact
  contract. `SQSProcessor` itself is untouched: every `process_*_event/1`
  function stays SES-shaped, this module's only job is translating Brevo's
  vocabulary into it.

  A raw Brevo event looks like:

      %{
        "date" => "2017-03-12T12:30:00Z",
        "email" => "john.smith@example.com",
        "event" => "delivered",
        "messageId" => "<201798300811.5787683@example.domain.com>",
        "reason" => "...",       # bounces/blocked/invalid/error only
        "link" => "...",         # clicks only
        "ip" => "..."            # opened/clicks only
      }

  `date` is already full ISO 8601 with a `Z` offset — `SQSProcessor`'s own
  `parse_timestamp/1` (`DateTime.from_iso8601/1`) accepts it unmodified, no
  reformatting needed.
  """

  @doc """
  Normalizes a raw Brevo event.

  ## Returns

  - `{:ok, event_data}` — ready for `SQSProcessor.process_email_event/1`
  - `:ignore` — a Brevo `"requests"` event (the send-request acknowledgement;
    we already log our own "send" event at send time, so this carries
    nothing new)
  - `{:error, reason}` — missing required fields, or an event type Brevo
    added since this mapping was written
  """
  @spec normalize(map()) :: {:ok, map()} | :ignore | {:error, term()}
  def normalize(%{"event" => "requests"}), do: :ignore

  def normalize(%{"event" => event, "messageId" => message_id, "date" => date} = brevo_event)
      when is_binary(event) and is_binary(message_id) and is_binary(date) do
    case build(event, brevo_event, date) do
      {event_type, sub_key, sub_map} ->
        {:ok,
         %{
           "eventType" => event_type,
           "mail" => %{"messageId" => message_id, "provider" => "brevo_api"},
           sub_key => sub_map
         }}

      :unknown ->
        {:error, {:unknown_brevo_event_type, event}}
    end
  end

  def normalize(_), do: {:error, :missing_required_fields}

  defp build("delivered", _brevo_event, date) do
    {"delivery", "delivery", %{"timestamp" => date}}
  end

  defp build("hardBounces", brevo_event, date) do
    {"bounce", "bounce", bounce_data(brevo_event, date, "Permanent")}
  end

  defp build("softBounces", brevo_event, date) do
    {"bounce", "bounce", bounce_data(brevo_event, date, "Transient")}
  end

  # Brevo's aggregate "bounces" type (bounce sub-type unspecified) —
  # SQSProcessor.determine_bounce_status/1 already treats an unrecognized
  # bounceType as the generic "bounced" status.
  defp build("bounces", brevo_event, date) do
    {"bounce", "bounce", bounce_data(brevo_event, date, nil)}
  end

  defp build("opened", brevo_event, date) do
    {"open", "open", %{"timestamp" => date, "ipAddress" => brevo_event["ip"]}}
  end

  # A proxy pre-fetched the tracking pixel rather than the recipient
  # actually opening it (e.g. Apple Mail Privacy Protection). Still an
  # "open" for SQSProcessor's purposes, but the `proxy: true` marker
  # rides along in the event's raw `event_data` JSONB for anyone
  # auditing engagement metrics later.
  defp build("loadedByProxy", brevo_event, date) do
    {"open", "open", %{"timestamp" => date, "ipAddress" => brevo_event["ip"], "proxy" => true}}
  end

  defp build("clicks", brevo_event, date) do
    {"click", "click",
     %{"timestamp" => date, "link" => brevo_event["link"], "ipAddress" => brevo_event["ip"]}}
  end

  defp build("spam", _brevo_event, date) do
    {"complaint", "complaint", %{"timestamp" => date}}
  end

  defp build("deferred", brevo_event, date) do
    {"delivery_delay", "deliveryDelay", %{"timestamp" => date, "reason" => brevo_event["reason"]}}
  end

  defp build("blocked", brevo_event, date) do
    {"reject", "reject",
     %{"timestamp" => date, "reason" => brevo_event["reason"] || "Blocked by Brevo"}}
  end

  defp build("invalid", brevo_event, date) do
    {"reject", "reject",
     %{"timestamp" => date, "reason" => brevo_event["reason"] || "Invalid email address"}}
  end

  defp build("error", brevo_event, date) do
    {"reject", "reject", %{"timestamp" => date, "reason" => brevo_event["reason"] || "Error"}}
  end

  defp build("unsubscribed", _brevo_event, date) do
    {"subscription", "subscription", %{"timestamp" => date, "subscriptionType" => "unsubscribe"}}
  end

  defp build(_unknown, _brevo_event, _date), do: :unknown

  defp bounce_data(brevo_event, date, bounce_type) do
    %{
      "timestamp" => date,
      "bounceType" => bounce_type,
      "bouncedRecipients" => [%{"emailAddress" => brevo_event["email"]}]
    }
  end
end
