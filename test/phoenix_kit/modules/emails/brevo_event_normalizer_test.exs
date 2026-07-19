defmodule PhoenixKit.Modules.Emails.BrevoEventNormalizerTest do
  @moduledoc """
  Every Brevo event type `SQSProcessor.process_email_event/1` needs to be
  able to consume, per `GetEmailEventReportResponseEventsItem` (Brevo's
  own published event shape — see `BrevoEventNormalizer`'s moduledoc).
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.BrevoEventNormalizer, as: Normalizer

  @message_id "<201798300811.5787683@example.domain.com>"
  @date "2017-03-12T12:30:00Z"

  defp brevo_event(event, extra \\ %{}) do
    Map.merge(
      %{
        "date" => @date,
        "email" => "john.smith@example.com",
        "event" => event,
        "messageId" => @message_id
      },
      extra
    )
  end

  test "delivered -> delivery" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("delivered"))

    assert event_data == %{
             "eventType" => "delivery",
             "mail" => %{"messageId" => @message_id, "provider" => "brevo_api"},
             "delivery" => %{"timestamp" => @date}
           }
  end

  test "hardBounces -> bounce/Permanent, carries bouncedRecipients for blocklisting" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("hardBounces"))

    assert event_data["eventType"] == "bounce"
    assert event_data["mail"] == %{"messageId" => @message_id, "provider" => "brevo_api"}
    assert event_data["bounce"]["bounceType"] == "Permanent"
    assert event_data["bounce"]["timestamp"] == @date

    assert event_data["bounce"]["bouncedRecipients"] == [
             %{"emailAddress" => "john.smith@example.com"}
           ]
  end

  test "softBounces -> bounce/Transient" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("softBounces"))
    assert event_data["eventType"] == "bounce"
    assert event_data["bounce"]["bounceType"] == "Transient"
  end

  test "bounces (generic) -> bounce with no bounceType" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("bounces"))
    assert event_data["eventType"] == "bounce"
    assert event_data["bounce"]["bounceType"] == nil
  end

  test "opened -> open" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("opened", %{"ip" => "1.2.3.4"}))

    assert event_data == %{
             "eventType" => "open",
             "mail" => %{"messageId" => @message_id, "provider" => "brevo_api"},
             "open" => %{"timestamp" => @date, "ipAddress" => "1.2.3.4"}
           }
  end

  test "loadedByProxy -> open, marked proxy: true in the raw sub-map" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("loadedByProxy"))

    assert event_data["eventType"] == "open"
    assert event_data["open"]["proxy"] == true
  end

  test "clicks -> click, carries link + ip" do
    assert {:ok, event_data} =
             Normalizer.normalize(
               brevo_event("clicks", %{"link" => "https://example.com", "ip" => "1.2.3.4"})
             )

    assert event_data == %{
             "eventType" => "click",
             "mail" => %{"messageId" => @message_id, "provider" => "brevo_api"},
             "click" => %{
               "timestamp" => @date,
               "link" => "https://example.com",
               "ipAddress" => "1.2.3.4"
             }
           }
  end

  test "spam -> complaint" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("spam"))
    assert event_data["eventType"] == "complaint"
  end

  test "deferred -> delivery_delay, carries the Brevo reason" do
    assert {:ok, event_data} =
             Normalizer.normalize(brevo_event("deferred", %{"reason" => "Mailbox full"}))

    assert event_data["eventType"] == "delivery_delay"
    assert event_data["deliveryDelay"]["reason"] == "Mailbox full"
  end

  test "blocked -> reject, with a fallback reason when Brevo doesn't send one" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("blocked"))
    assert event_data["eventType"] == "reject"
    assert event_data["reject"]["reason"] == "Blocked by Brevo"
  end

  test "invalid -> reject" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("invalid"))
    assert event_data["eventType"] == "reject"
    assert event_data["reject"]["reason"] == "Invalid email address"
  end

  test "error -> reject" do
    assert {:ok, event_data} =
             Normalizer.normalize(brevo_event("error", %{"reason" => "SMTP 550"}))

    assert event_data["eventType"] == "reject"
    assert event_data["reject"]["reason"] == "SMTP 550"
  end

  test "unsubscribed -> subscription" do
    assert {:ok, event_data} = Normalizer.normalize(brevo_event("unsubscribed"))
    assert event_data["eventType"] == "subscription"
    assert event_data["subscription"]["subscriptionType"] == "unsubscribe"
  end

  test "requests is ignored — it's our own send-request, not a new event" do
    assert :ignore = Normalizer.normalize(brevo_event("requests"))
  end

  test "an unrecognized event type errors instead of silently dropping" do
    assert {:error, {:unknown_brevo_event_type, "somethingNew"}} =
             Normalizer.normalize(brevo_event("somethingNew"))
  end

  test "missing required fields errors" do
    assert {:error, :missing_required_fields} = Normalizer.normalize(%{"event" => "delivered"})
    assert {:error, :missing_required_fields} = Normalizer.normalize(%{})
  end
end
