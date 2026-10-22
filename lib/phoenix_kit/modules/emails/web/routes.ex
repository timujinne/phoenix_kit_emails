defmodule PhoenixKit.Modules.Emails.Web.Routes do
  @moduledoc """
  Public route definitions for Emails module.
  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  """

  def generate(url_prefix) do
    webhook_controller = PhoenixKit.Modules.Emails.Web.WebhookController
    export_controller = PhoenixKit.Modules.Emails.Web.ExportController
    runner_script_controller = PhoenixKit.Modules.Emails.Web.RunnerScriptController

    quote do
      # AWS SNS delivers webhook notifications as a cold, session-less POST
      # — it never carries a CSRF token or session cookie. Routing it
      # through the host's :browser pipeline (protect_from_forgery) would
      # 403 every notification. Deliberately minimal/self-contained so it
      # doesn't assume anything about what else the host app's :browser
      # pipeline includes (mirrors the newsletters one-click unsubscribe
      # pipeline).
      pipeline :phoenix_kit_emails_webhook do
        plug(:accepts, ["html"])
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

      # The SMTP runner script: a download behind the admin pipeline; the controller
      # adds the "emails" permission.
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_admin_only])

        get(
          "/admin/emails/verification/pk-smtp-runner.ps1",
          unquote(runner_script_controller),
          :runner_script
        )
      end
    end
  end
end
