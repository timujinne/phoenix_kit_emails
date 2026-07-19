defmodule PhoenixKit.Modules.Emails.Web.WebhookRouteCSRFTest do
  @moduledoc """
  Router-level regression test for the SES webhook route's pipeline.

  AWS SNS delivers the `/webhooks/ses` notification as a cold,
  session-less POST. Routing it through a `:browser`-style pipeline with
  `protect_from_forgery` raises `Plug.CSRFProtection.InvalidCSRFTokenError`
  before the request ever reaches `WebhookController`. This builds a
  router the same way a host app's own router would (via
  `phoenix_kit_routes()`) — using the *actual* AST returned by
  `Routes.generate/1` — and dispatches a cold POST through it end to end.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Settings

  defmodule TestRouter do
    use Phoenix.Router

    alias PhoenixKit.Modules.Emails.Web.Routes

    # Mirrors a typical host app's own pipelines (Phoenix's default
    # generator puts protect_from_forgery in :browser). :phoenix_kit_admin_only
    # is only referenced by the (unrelated, admin-only) export route.
    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
    end

    pipeline :phoenix_kit_admin_only do
      plug(:accepts, ["html"])
    end

    Code.eval_quoted(Routes.generate("/phoenix_kit"), [], __ENV__)
  end

  # The "before" half, kept permanently rather than by reverting the real
  # fix: routes the webhook through :browser directly — the exact shape
  # the bug had — so this regression test doesn't depend on
  # Routes.generate/1 staying broken to prove anything.
  defmodule BeforeFixRouter do
    use Phoenix.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
    end

    scope "/phoenix_kit" do
      pipe_through([:browser])
      post("/webhooks/ses", PhoenixKit.Modules.Emails.Web.WebhookController, :handle)
    end
  end

  setup do
    Settings.update_boolean_setting("webhook_verify_sns_signature", false)
    Settings.update_boolean_setting("webhook_check_aws_ip", false)
    Settings.update_boolean_setting("webhook_rate_limit_enabled", false)
    :ok
  end

  defp cold_conn do
    params = %{
      "Type" => "UnsubscribeConfirmation",
      "TopicArn" => "arn:aws:sns:us-east-1:123456789012:test-topic",
      "SubscriptionArn" => "arn:aws:sns:us-east-1:123456789012:test-topic:sub",
      "Timestamp" => DateTime.to_iso8601(DateTime.utc_now())
    }

    session_opts = Plug.Session.init(store: :cookie, key: "_test", signing_salt: "test_salt")

    Plug.Test.conn(:post, "/phoenix_kit/webhooks/ses")
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(session_opts)
    |> Map.put(:params, params)
  end

  test "before: :browser pipe_through 403s a cold POST with InvalidCSRFTokenError" do
    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        cold_conn() |> BeforeFixRouter.call(BeforeFixRouter.init([]))
      end

    assert %Plug.CSRFProtection.InvalidCSRFTokenError{} = error.reason
  end

  test "after: a cold POST with no session/CSRF token reaches the controller instead of being CSRF-blocked" do
    conn = cold_conn() |> TestRouter.call(TestRouter.init([]))

    assert conn.status == 200
    assert conn.resp_body == "OK"
  end
end
