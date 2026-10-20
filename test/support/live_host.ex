defmodule PhoenixKitEmails.Test.LiveEndpoint do
  @moduledoc """
  A minimal endpoint so that a settings section can run inside a real LiveView
  (`Phoenix.LiveViewTest.live_isolated/3`): the page process, the component, its events
  and `send_update/3` behave as on the Email Sending page. `server: false`, so nothing
  listens on a port.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_emails

  @session_options [store: :cookie, key: "_emails_test_key", signing_salt: "emails_test"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
end

defmodule PhoenixKitEmails.Test.SectionHost do
  @moduledoc """
  A LiveView page that hosts one settings section the way core's Email Sending page
  does: `<.live_component module=... id=... />` with nothing else. The signed-in admin
  is an assign of the page, as in core.
  """

  use Phoenix.LiveView

  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification

  @impl true
  def mount(_params, session, socket) do
    {:ok, assign(socket, :phoenix_kit_current_scope, session["scope"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component module={SmtpVerification} id="smtp-verification" />
    """
  end
end
