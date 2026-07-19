defmodule PhoenixKit.Modules.Emails.BrevoEventsIntegrationTest do
  @moduledoc """
  End-to-end round trip for the Brevo event pipeline, entirely within this
  package's own `Log`/`Event` tables (the newsletters `Delivery` sync is a
  cross-package soft dependency — `phoenix_kit_newsletters` isn't a
  dependency of this repo, so `maybe_update_newsletters_delivery/3`
  no-ops here via `PhoenixKit.ModuleRegistry`; it's unchanged, generic
  code and gets the same wiring automatically once both packages are
  installed together, same as it already does for SES).

  This proves the two things that make Brevo events usable at all:
  1. `Interceptor` recovers Brevo's own message id into `aws_message_id`
     at send time (see `InterceptorBrevoTest`).
  2. A polled Brevo event, once normalized, finds that log BY that id and
     updates it — exactly the correlation `find_email_log_by_message_id/1`
     was already doing for SES, now working for Brevo too.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoEventNormalizer
  alias PhoenixKit.Modules.Emails.Event
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKitEmails.Test.Repo

  setup do
    # find_email_log_by_message_id/1 (via Emails.get_log_by_message_id/1)
    # refuses to look anything up while the system is disabled — matches
    # a real deployment, where this is always on once the module's
    # configured, but this standalone suite starts with it off.
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp create_sent_brevo_log(brevo_message_id) do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "brevo_api",
        status: "queued"
      })
      |> Repo.insert()

    {:ok, sent_log} = Interceptor.update_after_send(log, %{"messageId" => brevo_message_id})
    sent_log
  end

  test "a polled Brevo 'delivered' event finds the log by its recovered message id and marks it delivered" do
    brevo_message_id = "<brevo-#{System.unique_integer([:positive])}@brevo.com>"
    log = create_sent_brevo_log(brevo_message_id)
    assert log.aws_message_id == brevo_message_id

    brevo_event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "delivered",
      "messageId" => brevo_message_id
    }

    assert {:ok, normalized} = BrevoEventNormalizer.normalize(brevo_event)

    assert {:ok, %{type: "delivery", updated: true}} =
             SQSProcessor.process_email_event(normalized)

    reloaded = Repo.get(Log, log.uuid)
    assert reloaded.status == "delivered"
    assert reloaded.delivered_at != nil
  end

  test "reprocessing the same Brevo event twice is idempotent (no duplicate Event row)" do
    brevo_message_id = "<brevo-#{System.unique_integer([:positive])}@brevo.com>"
    log = create_sent_brevo_log(brevo_message_id)

    brevo_event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "opened",
      "messageId" => brevo_message_id,
      "ip" => "1.2.3.4"
    }

    {:ok, normalized} = BrevoEventNormalizer.normalize(brevo_event)

    assert {:ok, _} = SQSProcessor.process_email_event(normalized)
    assert {:ok, _} = SQSProcessor.process_email_event(normalized)

    events =
      Event
      |> where(email_log_uuid: ^log.uuid, event_type: "open")
      |> Repo.all()

    assert length(events) == 1
  end

  test "a Brevo hard bounce blocklists the recipient, same as an SES hard bounce would" do
    brevo_message_id = "<brevo-#{System.unique_integer([:positive])}@brevo.com>"
    _log = create_sent_brevo_log(brevo_message_id)

    brevo_event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "hardBounces",
      "messageId" => brevo_message_id
    }

    {:ok, normalized} = BrevoEventNormalizer.normalize(brevo_event)
    assert {:ok, _} = SQSProcessor.process_email_event(normalized)

    assert {:blocked, _} = RateLimiter.check_blocklist("recipient@example.com")
  end

  test "a Brevo event with no matching log creates a placeholder labeled provider brevo_api, not aws_ses" do
    {:ok, _} = Emails.set_placeholder_logs(true)

    brevo_message_id = "<brevo-#{System.unique_integer([:positive])}@brevo.com>"

    brevo_event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "delivered",
      "messageId" => brevo_message_id
    }

    {:ok, normalized} = BrevoEventNormalizer.normalize(brevo_event)
    assert {:ok, %{updated: true}} = SQSProcessor.process_email_event(normalized)

    placeholder = Repo.get_by(Log, message_id: brevo_message_id)
    assert placeholder.provider == "brevo_api"
  end
end
