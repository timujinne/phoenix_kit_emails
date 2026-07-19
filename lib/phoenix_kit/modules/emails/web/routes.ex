defmodule PhoenixKit.Modules.Emails.Web.Routes do
  @moduledoc """
  Public route definitions for Emails module.
  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  """

  def generate(url_prefix) do
    webhook_controller = PhoenixKit.Modules.Emails.Web.WebhookController
    export_controller = PhoenixKit.Modules.Emails.Web.ExportController

    quote do
      # AWS SNS delivers webhook notifications as a cold, session-less POST
      # — it never carries a CSRF token or session cookie. Routing it
      # through the host's :browser pipeline (protect_from_forgery) would
      # 403 every notification. Deliberately minimal/self-contained so it
      # doesn't assume anything about what else the host app's :browser
      # pipeline includes (mirrors the newsletters one-click unsubscribe
      # pipeline).
      #
      # "Public" here means without a session — not without authentication.
      # WebhookController itself is the auth boundary: SNS message
      # signature verification (WebhookController.handle/2, gated by
      # webhook_verify_sns_signature, default on), an AWS-IP allowlist
      # (webhook_check_aws_ip, default on), and a 5-minute replay window
      # (verify_request_age/1) all run before any event is processed.
      pipeline :phoenix_kit_emails_webhook do
        # SNS posts "application/json" (Notification/SubscriptionConfirmation
        # payloads) — ["json"] describes what this endpoint actually accepts,
        # unlike ["html"] which was never true for a JSON-only webhook.
        # Behaviorally inert either way: :accepts only negotiates response
        # format/Accept-header handling, it doesn't gate the request body.
        plug(:accepts, ["json"])
      end

      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_emails_webhook])
        post("/webhooks/ses", unquote(webhook_controller), :handle)
      end

      # Export requires admin authentication
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_admin_only])
        get("/emails/export/:format", unquote(export_controller), :export)
      end
    end
  end
end
