defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerificationLiveTest do
  @moduledoc """
  The section inside a real LiveView, as on core's Email Sending page. While a runner
  is online the section is patched every few seconds (the "answered N s ago" text), and
  the sender, HELO and number fields must keep what the admin has typed and the
  "Advanced" block must keep its state across those patches.
  """

  # Not async: the API processes, the module registry and the PubSub manager are named.
  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  import PhoenixKitEmails.Test.ApiHarness

  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification.Relay
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitEmails.Test.LiveEndpoint
  alias PhoenixKitEmails.Test.SectionHost

  @endpoint LiveEndpoint

  setup do
    setup_api()
    put_setting("from_email", "mail@acme-mail.test")
    put_setting("email_verify_smtp_mode", "runner")
    start_supervised!(LiveEndpoint)

    {admin, _role} = user_with(["emails"])
    {key, _token} = issue_key(admin)

    Runners.heartbeat(
      %{key_uuid: key.uuid, ip: "203.0.113.7"},
      %{name: "WORKSTATION", port25: "open", version: "1.0.0"},
      DateTime.add(DateTime.utc_now(), -5)
    )

    {:ok, view, _html} =
      live_isolated(build_conn(), SectionHost, session: %{"scope" => scope_of(admin)})

    %{view: view}
  end

  defp settings_form(view), do: form(view, "#smtp-verification-settings")

  defp tick(view) do
    Phoenix.LiveView.send_update(view.pid, SmtpVerification,
      id: "smtp-verification",
      relay_event: :tick
    )

    render(view)
  end

  test "shows the runner online in the page", %{view: view} do
    assert render(view) =~ ~r/answered \d+ s ago/
  end

  test "what is typed in the form survives the live updates", %{view: view} do
    settings_form(view)
    |> render_change(%{
      "smtp" => %{
        "mail_from" => "verify@acme-mail.test",
        "helo" => "mx.acme-mail.test",
        "rcpt_per_session" => "7"
      }
    })

    tick(view)
    send(view.pid, :ignored)
    html = tick(view)

    assert html =~ ~s(value="verify@acme-mail.test")
    assert html =~ ~s(value="mx.acme-mail.test")
    assert html =~ ~s(name="smtp[rcpt_per_session]")

    assert html =~
             ~r/name="smtp\[rcpt_per_session\]"[^>]*value="7"|value="7"[^>]*name="smtp\[rcpt_per_session\]"/s
  end

  test "an announcement of the runner keeps the typed values too", %{view: view} do
    settings_form(view) |> render_change(%{"smtp" => %{"mail_from" => "verify@acme-mail.test"}})

    Phoenix.LiveView.send_update(view.pid, SmtpVerification,
      id: "smtp-verification",
      relay_event: :runner
    )

    assert render(view) =~ ~s(value="verify@acme-mail.test")
  end

  test "the Advanced block stays open across the live updates", %{view: view} do
    assert render(view) =~ ~r/id="smtp-verification-advanced"[^>]*class="[^"]*hidden/

    view |> element("button[phx-click=toggle_advanced]") |> render_click()
    refute tick(view) =~ ~r/id="smtp-verification-advanced"[^>]*class="[^"]*hidden/

    view |> element("button[phx-click=toggle_advanced]") |> render_click()
    assert tick(view) =~ ~r/id="smtp-verification-advanced"[^>]*class="[^"]*hidden/
  end

  test "the section reads the admin out of the page", %{view: view} do
    # The relay asks the page process; give it a moment to answer.
    assert eventually(fn -> not (render(view) =~ "Your account cannot be read here") end)
    assert render(view) =~ "Issue a new token"
  end

  test "the relay reads the scope out of the state of a real LiveView", %{view: view} do
    # The tripwire for `Relay.scope_of/2`: it reads the state of the LiveView process, whose
    # shape is LiveView's own. A LiveView that changes it fails here, not silently in prod.
    assert %Scope{} = Relay.scope_of(view.pid)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
