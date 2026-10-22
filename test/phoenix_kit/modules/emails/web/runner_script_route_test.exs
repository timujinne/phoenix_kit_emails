defmodule PhoenixKit.Modules.Emails.Web.RunnerScriptRouteTest do
  @moduledoc """
  The download of the SMTP runner script, through a router built the way a host app's is
  (`Routes.generate/1`) with core's own admin pipeline: an anonymous visitor is sent to
  the login, an admin without the `emails` permission gets a 403, an admin with it gets
  the file as an attachment.
  """

  # Not async: the users, roles and session tokens are real rows and the Owner is the
  # first user ever registered.
  use PhoenixKitEmails.DataCase, async: false

  import PhoenixKitEmails.Test.ApiHarness, only: [setup_api: 0, user_with: 1]
  import Plug.Conn

  alias PhoenixKit.Modules.Emails.Paths
  alias PhoenixKit.Modules.Emails.Web.RunnerScriptController
  alias PhoenixKit.Users.Auth

  defmodule TestRouter do
    use Phoenix.Router

    alias PhoenixKit.Modules.Emails.Web.Routes

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:fetch_flash)
    end

    # The same plugs as core's `:phoenix_kit_admin_only` pipeline.
    pipeline :phoenix_kit_admin_only do
      plug(PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_user)
      plug(PhoenixKitWeb.Users.Auth, :fetch_phoenix_kit_current_scope)
      plug(PhoenixKitWeb.Users.Auth, :phoenix_kit_require_admin)
    end

    Code.eval_quoted(Routes.generate("/phoenix_kit"), [], __ENV__)
  end

  @path "/phoenix_kit/admin/emails/verification/pk-smtp-runner.ps1"

  # Starts what core's plugs and the users need and registers the Owner, so that the
  # users of the tests are ordinary ones.
  setup do
    setup_api()
    :ok
  end

  defp get_script(user \\ nil) do
    conn = Plug.Test.conn(:get, @path)

    conn =
      if user do
        token = Auth.generate_user_session_token(user)
        Plug.Test.init_test_session(conn, %{user_token: token})
      else
        Plug.Test.init_test_session(conn, %{})
      end

    TestRouter.call(conn, TestRouter.init([]))
  end

  test "the module's own path helper points at the route" do
    assert Paths.runner_script() =~ "/admin/emails/verification/pk-smtp-runner.ps1"
  end

  test "an anonymous visitor is sent to the login" do
    conn = get_script()

    assert conn.status == 302
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/users/log-in"
    assert conn.resp_body =~ "redirected"
    refute conn.resp_body =~ "SMTP"
  end

  test "an admin without the emails permission gets a 403 and no script" do
    {user, _role} = user_with(["settings"])

    conn = get_script(user)

    assert conn.status == 403
    refute conn.resp_body =~ "Write-Error"
  end

  test "an admin with the emails permission downloads the script" do
    {user, _role} = user_with(["emails"])

    conn = get_script(user)

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type == "text/plain; charset=utf-8"

    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ ~s(filename="pk-smtp-runner.ps1")

    assert conn.resp_body == File.read!(RunnerScriptController.script_path())
  end
end
