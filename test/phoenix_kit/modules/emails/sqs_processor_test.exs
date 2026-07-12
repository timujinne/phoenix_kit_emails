defmodule PhoenixKit.Modules.Emails.SQSProcessorTest do
  @moduledoc """
  Hard (Permanent) SES bounces auto-add the bounced recipient(s) to the rate
  limiter's blocklist; transient bounces must not (Stage E, E1).
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.SQSProcessor

  setup do
    # find_email_log_by_message_id/1 routes through Emails.get_log_by_message_id/1,
    # which no-ops with {:error, :system_disabled} unless the emails system is on.
    Emails.enable_system()
    :ok
  end

  defp unique_message_id, do: "msg-\#{System.unique_integer([:positive, :monotonic])}"

  defp bounce_event(bounce_type, recipients, message_id) do
    %{
      "eventType" => "Bounce",
      "mail" => %{
        "messageId" => message_id,
        "destination" => Enum.map(recipients, & &1["emailAddress"]),
        "source" => "sender@example.com",
        "commonHeaders" => %{"subject" => "Test"},
        "timestamp" => "2026-07-12T10:00:00.000Z"
      },
      "bounce" => %{
        "bounceType" => bounce_type,
        "bounceSubType" => "General",
        "bouncedRecipients" => recipients,
        "timestamp" => "2026-07-12T10:00:00.000Z"
      }
    }
  end

  defp create_log_for(message_id, to_email) do
    {:ok, log} =
      Log.create_log(%{
        message_id: message_id,
        to: to_email,
        from: "sender@example.com",
        provider: "aws_ses",
        status: "sent"
      })

    log
  end

  describe "process_email_event/1 — bounce" do
    test "a Permanent bounce adds every bounced recipient to the blocklist as hard_bounce" do
      message_id = unique_message_id()

      recipients = [
        %{
          "emailAddress" => "bounced1@example.com",
          "status" => "5.1.1",
          "diagnosticCode" => "smtp; 550 5.1.1 unknown user"
        },
        %{
          "emailAddress" => "bounced2@example.com",
          "status" => "5.1.1",
          "diagnosticCode" => "smtp; 550 5.1.1 unknown user"
        }
      ]

      create_log_for(message_id, "bounced1@example.com")

      assert {:ok, _} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      assert RateLimiter.is_blocked?("bounced1@example.com")
      assert RateLimiter.is_blocked?("bounced2@example.com")

      assert [%{reason: "hard_bounce"}] =
               RateLimiter.list_blocklist(%{search: "bounced1@example.com"})
    end

    test "a Transient bounce does not add the recipient to the blocklist" do
      message_id = unique_message_id()

      recipients = [
        %{
          "emailAddress" => "softbounce@example.com",
          "status" => "4.2.2",
          "diagnosticCode" => "smtp; 450 4.2.2 mailbox full"
        }
      ]

      create_log_for(message_id, "softbounce@example.com")

      assert {:ok, _} =
               SQSProcessor.process_email_event(bounce_event("Transient", recipients, message_id))

      refute RateLimiter.is_blocked?("softbounce@example.com")
    end

    test "a Permanent bounce blocklists the recipient even when no matching email log exists" do
      message_id = unique_message_id()
      recipients = [%{"emailAddress" => "orphan-bounce@example.com", "status" => "5.1.1"}]

      assert {:error, :email_log_not_found} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))

      assert RateLimiter.is_blocked?("orphan-bounce@example.com")
    end

    test "a blocklist failure (invalid recipient address) does not break bounce event processing" do
      message_id = unique_message_id()
      recipients = [%{"emailAddress" => "not-an-email", "status" => "5.1.1"}]

      assert {:error, :email_log_not_found} =
               SQSProcessor.process_email_event(bounce_event("Permanent", recipients, message_id))
    end
  end
end
