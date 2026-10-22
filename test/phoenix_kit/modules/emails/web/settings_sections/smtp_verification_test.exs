defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerificationTest do
  @moduledoc """
  The "Mailbox verification (SMTP)" section: what it renders in each state (off, local,
  a runner that is online, offline, never connected, paused, without a sender, with a
  key whose owner is gone), the preconditions with their links, and every event: the
  mode, the form, issuing and revoking the token, resuming, and switching the machine
  API on after a confirmation.

  Like the sections next door it is rendered through `render_component/3` against the
  stub endpoint, and its events are called on a bare socket.
  """

  # Not async: the API processes, the module registry and the PubSub manager are named.
  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PhoenixKitEmails.Test.ApiHarness
  import PhoenixKitEmails.Test.SmtpHelpers, only: [unique_domain: 0]

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.LocalRunner
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.RunnerSetup
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification.Relay
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  setup do
    setup_api()
    put_setting("from_email", "mail@acme-mail.test")
    FakeResolver.put("acme-mail.test", mx: {:ok, [%{host: "mx.acme-mail.test", pref: 10}]})

    {admin, role} = user_with(["emails"])
    %{admin: admin, role: role, scope: scope_of(admin)}
  end

  ## --- Helpers ---

  defp render_section(assigns \\ %{}) do
    render_component(
      SmtpVerification,
      Map.merge(%{id: "smtp-verification"}, assigns),
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  defp put_mode(mode), do: put_setting("email_verify_smtp_mode", mode)

  # The component as a connected page leaves it after the first update, on a bare socket.
  defp socket(assigns \\ %{}) do
    {:ok, socket} =
      SmtpVerification.update(
        Map.merge(%{id: "smtp-verification"}, assigns),
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
      )

    socket
  end

  defp event(socket, name, params \\ %{}) do
    {:noreply, socket} = SmtpVerification.handle_event(name, params, socket)
    socket
  end

  defp flash(socket, kind), do: socket.assigns.flash[to_string(kind)]

  defp runner_key({user, _role}), do: runner_key(user)

  defp runner_key(user) do
    {key, token} = issue_key(user)
    {key, token}
  end

  # A runner that called `seconds` ago.
  defp heartbeat(key, seconds_ago, info \\ %{}) do
    info = Map.merge(%{name: "WORKSTATION", port25: "open", version: "1.0.0"}, info)
    now = DateTime.add(DateTime.utc_now(), -seconds_ago)
    Runners.heartbeat(%{key_uuid: key.uuid, ip: "203.0.113.7"}, info, now)
  end

  defp live_keys do
    Repo.all(from(k in Key, order_by: k.inserted_at))
    |> Enum.filter(&(Keys.dead_reason(&1) == nil))
  end

  defp user_without_api do
    {:ok, role} =
      Roles.create_role(%{name: "NoApi#{System.unique_integer([:positive])}"})

    {:ok, _} = Permissions.grant_permission(role.uuid, "emails")

    {:ok, user} =
      Auth.register_user(
        %{
          email: "noapi#{System.unique_integer([:positive])}@acme-mail.test",
          password: "ValidPassword123!"
        },
        nil
      )

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  ## --- Rendering ---

  describe "in the list of the Email Sending page" do
    test "is declared as a section with the emails permission" do
      assert %{
               id: :emails_verification_smtp,
               title: "Mailbox verification (SMTP)",
               permission: "emails",
               component: SmtpVerification
             } =
               Enum.find(Emails.email_settings_sections(), &(&1.id == :emails_verification_smtp))
    end
  end

  describe "mode off (the default)" do
    test "offers the three modes with off selected and no runner panel" do
      html = render_section()

      assert html =~ "Mailbox check"
      assert Regex.match?(~r/<input[^>]*name="mode"[^>]*value="off"[^>]*checked/s, html)
      refute Regex.match?(~r/<input[^>]*value="local"[^>]*checked/s, html)
      assert html =~ "Domain OK, no SMTP"
      refute html =~ "Issue a new token"
      refute html =~ "Connecting"
    end

    test "has no sender or HELO fields: no connection is opened" do
      html = render_section()

      refute html =~ ~s|name="smtp[mail_from]"|
      refute html =~ "HELO name"
    end

    test "warns under the this-server option, whatever is selected" do
      html = render_section()

      assert html =~ "Do not enable it if other sites share this IP address"
    end

    test "the radios are one labelled group wired to the section" do
      html = render_section()

      assert html =~ ~s|<legend class="fieldset-legend|
      assert html =~ ~s|phx-change="set_mode"|
      assert html =~ ~s|id="smtp-verification-mode"|
      assert html =~ "Runner on your computer"
    end

    # daisyUI's `label` does not wrap; on a 390 px screen a long option ran past the card.
    test "the text of every radio row wraps and the row does not outgrow the card" do
      labels =
        render_section()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s|form[id$="-mode"] label|)

      assert Enum.count(labels) == 3

      for label <- labels do
        row = label |> LazyHTML.attribute("class") |> hd() |> String.split()
        assert Enum.all?(~w(flex w-full items-start whitespace-normal), &(&1 in row))

        [text] =
          label
          |> LazyHTML.query("span")
          |> Enum.to_list()
          |> Enum.map(&LazyHTML.attribute(&1, "class"))

        assert Enum.all?(~w(min-w-0 flex-1), &(&1 in String.split(hd(text))))
      end
    end
  end

  describe "reading only what the mode shows" do
    test "off reads nothing about the runner or the core" do
      put_setting("api_admin_enabled", "false")
      {key, _token} = runner_key(elem(user_with(["emails"]), 0))
      heartbeat(key, 5)
      put_mode("off")

      socket = socket()

      assert socket.assigns.preconditions == []
      assert socket.assigns.active_keys == 0
      assert socket.assigns.status.runner == nil
      assert socket.assigns.relay == nil
    end

    test "local reads the built-in runner, never a remote one, and nothing of the core" do
      put_setting("api_admin_enabled", "false")
      {key, _token} = runner_key(elem(user_with(["emails"]), 0))
      heartbeat(key, 5)
      put_mode("local")

      socket = socket()

      assert socket.assigns.preconditions == []
      assert socket.assigns.active_keys == 0
      assert socket.assigns.status.runner == nil
      assert socket.assigns.status.owner == nil
      assert socket.assigns.local_info.host == LocalRunner.server_name()
    end

    test "runner reads them" do
      put_setting("api_admin_enabled", "false")
      put_mode("runner")
      {key, _token} = runner_key(elem(user_with(["emails"]), 0))
      heartbeat(key, 5)

      socket = socket()

      assert :api_admin_disabled in socket.assigns.preconditions
      assert socket.assigns.active_keys == 1
      assert socket.assigns.status.runner.name == "WORKSTATION"
    end

    test "going to local starts the relay of a connected page too" do
      connected = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        transport_pid: self()
      }

      {:ok, socket} = SmtpVerification.update(%{id: "smtp-verification"}, connected)
      socket = socket |> event("set_mode", %{"mode" => "local"}) |> event("confirm_switch_local")
      relay = socket.assigns.relay
      assert is_pid(relay) and Process.alive?(relay)

      ref = Process.monitor(relay)
      socket = event(socket, "set_mode", %{"mode" => "off"})
      assert socket.assigns.relay == nil
      assert_receive {:DOWN, ^ref, :process, ^relay, _}, 1_000
    end

    test "going to runner starts the relay of a connected page and going away stops it" do
      connected = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        transport_pid: self()
      }

      {:ok, socket} = SmtpVerification.update(%{id: "smtp-verification"}, connected)
      assert socket.assigns.relay == nil

      socket = event(socket, "set_mode", %{"mode" => "runner"})
      relay = socket.assigns.relay
      assert is_pid(relay)
      assert Process.alive?(relay)

      ref = Process.monitor(relay)
      socket = event(socket, "set_mode", %{"mode" => "off"})
      assert socket.assigns.relay == nil
      assert_receive {:DOWN, ^ref, :process, ^relay, _}, 1_000
    end
  end

  describe "mode local" do
    setup do
      put_mode("local")
      :ok
    end

    test "selects this server and shows no token panel" do
      html = render_section()

      assert Regex.match?(~r/<input[^>]*value="local"[^>]*checked/s, html)
      assert html =~ ~s|id="smtp-verification-local"|
      refute html =~ "Issue a new token"
      refute html =~ "Connecting"
      refute html =~ "has no checker on the server yet"
    end

    test "warns that the connections go from the IP of the site" do
      html = render_section()

      assert html =~ "Do not enable it if other sites share this IP address"
    end

    test "says where the checks run and under which EHLO name" do
      put_setting("email_verify_smtp_helo", "mail.acme-mail.test")
      html = render_section()

      assert html =~ LocalRunner.server_name()
      assert html =~ "go out from its IP address, with the EHLO name mail.acme-mail.test"
    end

    test "the sender and HELO fields are there, the runner's instruction is not" do
      html = render_section()

      assert html =~ ~s|name="smtp[mail_from]"|
      assert html =~ "HELO name"
      refute html =~ "Connecting"
    end

    test "not started yet" do
      html = render_section()

      assert html =~ "Not started yet"
      assert html =~ "0 in the queue"
    end

    test "ready: the built-in runner has run and nothing waits" do
      Runners.heartbeat_local(%{name: "mailhost", port25: "open"}, DateTime.utc_now())
      html = render_section()

      assert html =~ "Ready"
      assert html =~ "mailhost"
      assert html =~ "port 25 open"
      refute html =~ "Not responding"
    end

    test "working: addresses wait in the queue" do
      Runners.heartbeat_local(%{name: "mailhost", port25: "open"}, DateTime.utc_now())
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})
      {:ok, _} = Verification.verify("info@#{domain}", smtp: :enqueue)

      html = render_section()

      assert html =~ "Working"
      assert html =~ "1 in the queue"
    end

    test "not responding: work waits and the last cycle is long ago" do
      Runners.heartbeat_local(%{name: "mailhost"}, DateTime.add(DateTime.utc_now(), -3600))
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})
      {:ok, _} = Verification.verify("info@#{domain}", smtp: :enqueue)

      html = render_section()

      assert html =~ "Not responding"
      assert html =~ "last cycle"
    end

    test "a closed port 25 is said so" do
      Runners.heartbeat_local(%{name: "mailhost", port25: "blocked"}, DateTime.utc_now())
      html = render_section()

      assert html =~ "port 25 closed"
      assert html =~ "Port 25 is closed on this server"
      refute html =~ "on the runner&#39;s machine"
    end

    test "no usable sender is said so" do
      put_setting("from_email", "noreply@localhost")
      html = render_section()

      assert html =~ "the server starts no sessions"
    end

    test "a pause shows its reason and the button to resume" do
      runner = Runners.heartbeat_local(%{name: "mailhost"}, DateTime.utc_now())

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [
          paused_until: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second),
          pause_reason: "5 sessions in a row failed"
        ]
      )

      html = render_section()
      assert html =~ "Paused: 5 sessions in a row failed"
      assert html =~ "Resume"

      socket = socket() |> event("clear_pause")
      assert socket.assigns.status.paused == nil
    end

    test "a remote runner's row is not shown as the built-in one" do
      {key, _token} = runner_key(elem(user_with(["emails"]), 0))
      heartbeat(key, 5, %{name: "WORKSTATION"})

      html = render_section()

      refute html =~ "WORKSTATION"
      assert html =~ "Not started yet"
    end
  end

  describe "mode runner" do
    setup do
      put_mode("runner")
      :ok
    end

    test "never connected", %{scope: scope} do
      html = render_section(%{phoenix_kit_current_scope: scope})

      assert html =~ "Not connected yet"
      assert html =~ "Issue a new token"
      assert html =~ "Revoke"
      assert html =~ "Connecting"
      assert html =~ "pk-smtp-runner.ps1"
      assert html =~ "-Server http"
      assert html =~ "&lt;token&gt;"
    end

    test "the instruction names the site's own address and the download route", %{scope: scope} do
      html = render_section(%{phoenix_kit_current_scope: scope})

      assert html =~ "-Server " <> RunnerSetup.server_url()
      assert RunnerSetup.server_url() =~ ~r{/phoenix_kit\z}
      assert html =~ ~s|href="#{Emails.Paths.runner_script()}"|
      assert html =~ " download"
    end

    test "online: how long ago, the machine, port 25 and the queue", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 12)

      html = render_section()

      assert html =~ "Online"
      assert html =~ "answered 12 s ago" or html =~ "answered 13 s ago"
      assert html =~ "WORKSTATION"
      assert html =~ "port 25 open"
      assert html =~ "0 in the queue"
      assert html =~ "bg-success"
    end

    test "the queue length is the queued and the leased addresses", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})
      {:ok, _} = Verification.verify("a@#{domain}", smtp: :enqueue)
      {:ok, _} = Verification.verify("b@#{domain}", smtp: :enqueue)

      assert render_section() =~ "2 in the queue"
    end

    test "offline: when it was last seen", %{admin: admin} do
      {key, _token} = runner_key(admin)
      runner = heartbeat(key, 3600)

      html = render_section()

      assert html =~ "Offline"
      assert html =~ "last seen " <> Calendar.strftime(runner.last_seen_at, "%d.%m %H:%M UTC")
      assert html =~ "bg-warning"
      refute html =~ "Online ·"
    end

    test "the seconds count as the idle poll says", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 50)
      put_setting("email_verify_smtp_idle_poll_s", "10")

      assert render_section() =~ "Offline"
    end

    test "port 25 closed on the runner's machine", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5, %{port25: "blocked"})

      html = render_section()

      assert html =~ "port 25 closed"
      assert html =~ "Port 25 is closed on the runner&#39;s machine"
    end

    test "paused: the reason and the button that lifts the pause", %{admin: admin} do
      {key, _token} = runner_key(admin)
      runner = heartbeat(key, 5)

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [
          paused_until: DateTime.add(DateTime.utc_now(), 3600),
          pause_reason: "5 sessions in a row failed on 3 domains"
        ]
      )

      html = render_section()

      assert html =~ "Paused: 5 sessions in a row failed on 3 domains"
      assert html =~ ~s|phx-click="clear_pause"|
      assert html =~ "Resume"
    end

    test "no sender address: no sessions" do
      put_setting("from_email", "noreply@localhost")

      html = render_section()

      assert html =~ "the runner starts no sessions"
      assert html =~ "There is no usable sender address; no session can start."
    end

    test "the sender in use and where it comes from" do
      html = render_section()

      assert html =~ "In use: mail@acme-mail.test (the sender address of the site)."
      assert html =~ ~s|placeholder="mail@acme-mail.test"|
      assert html =~ "Empty: the sender address of the site is used."

      put_setting("email_verify_smtp_mail_from", "verify@acme-mail.test")
      html = render_section()

      assert html =~ "In use: verify@acme-mail.test (set here)."
      assert html =~ ~s|value="verify@acme-mail.test"|
    end

    test "whose key the runner works with", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)

      html = render_section()

      assert html =~ "The runner works with the key of #{admin.email}."
      refute html =~ "The runner will stop"
    end

    test "whose key it is, before the runner has connected", %{admin: admin} do
      {_key, _token} = runner_key(admin)

      html = render_section()

      assert html =~ "Not connected yet"
      assert html =~ "The runner works with the key of #{admin.email}."
    end

    test "no runner key and no runner: nobody is named", %{admin: admin} do
      html = render_section()

      refute html =~ "The runner works with the key of"
      refute html =~ admin.email
    end

    test "the owner of the key is deactivated, before the runner has connected", %{admin: admin} do
      {_key, _token} = runner_key(admin)
      admin |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      html = render_section()

      assert html =~ "The runner will stop: the owner of its key, #{admin.email}, is deactivated."
      assert html =~ "alert-error"
    end

    test "the owner of the key is deactivated: the runner will stop", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)
      admin |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      html = render_section()

      assert html =~ "The runner will stop: the owner of its key, #{admin.email}, is deactivated."
      assert html =~ "alert-error"
    end

    test "the owner of the key lost the emails permission", %{admin: admin, role: role} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)
      :ok = Permissions.revoke_permission(role.uuid, "emails")

      html = render_section()

      assert html =~ "no longer has the &quot;emails&quot; permission"
    end

    test "a revoked key", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)
      {:ok, _} = Keys.revoke(key, admin.uuid)

      assert render_section() =~ "The runner&#39;s token was revoked"
    end

    test "the sender and HELO fields are labelled and the advanced block is collapsed" do
      html = render_section()

      assert html =~ ~s|for="smtp-verification-mail-from"|
      assert html =~ "Sender address (MAIL FROM)"
      assert html =~ ~s|name="smtp[mail_from]"|
      assert html =~ ~s|for="smtp-verification-helo"|
      assert html =~ "HELO name"
      assert html =~ "Empty: the reverse DNS name of the runner"

      assert html =~ "Advanced"
      assert html =~ "10 addresses per session, 10 s between sessions to a domain"
      assert html =~ "greylist retry 20 min × 3"
      refute Regex.match?(~r/<details[^>]*\bopen\b/, html)
      assert html =~ ~s|name="smtp[rcpt_per_session]"|
      assert html =~ ~s|for="smtp-verification-rcpt_per_session"|
    end

    test "the settings form submits to the section" do
      html = render_section()

      assert html =~ ~s|id="smtp-verification-settings"|
      assert html =~ ~s|phx-submit="save"|
    end
  end

  describe "the preconditions" do
    setup do
      put_mode("runner")
      :ok
    end

    test "none when the machine API is on", %{scope: scope} do
      html = render_section(%{phoenix_kit_current_scope: scope})

      refute html =~ "switched off"
      refute html =~ "Enable the machine API"
    end

    test "the admin API is off: a button, a link to Settings → API", %{scope: scope} do
      put_setting("api_admin_enabled", "false")

      html = render_section(%{phoenix_kit_current_scope: scope})

      assert html =~ "The machine API is switched off, so the runner cannot connect."
      assert html =~ ~s|phx-click="request_enable_api"|
      assert html =~ "Settings → API"
      assert html =~ "/admin/settings/api"
    end

    test "the button needs the api permission" do
      put_setting("api_admin_enabled", "false")

      html = render_section(%{phoenix_kit_current_scope: scope_of(user_without_api())})

      assert Regex.match?(~r/<button[^>]*request_enable_api[^>]*disabled/s, html) or
               Regex.match?(~r/<button[^>]*disabled[^>]*request_enable_api/s, html)

      assert html =~ "You need the API permission for this."
    end

    test "emails in api_disabled_modules" do
      put_setting("api_disabled_modules", "emails")

      assert render_section() =~ "The API of the Emails module is switched off"
    end

    test "tools hidden in api_disabled_tools" do
      put_setting("api_disabled_tools", "emails.claim_smtp_jobs")

      html = render_section()

      assert html =~ "These runner tools are hidden"
      assert html =~ "emails.claim_smtp_jobs"
    end

    test "a core without the machine API: a hint, the runner mode is not offered" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      html = render_section()

      assert html =~ "This version of PhoenixKit has no machine API"
      assert Regex.match?(~r/<input[^>]*value="runner"[^>]*disabled/s, html)
    end
  end

  describe "the token buttons" do
    setup do
      put_mode("runner")
      :ok
    end

    test "are off until the admin is known" do
      html = render_section()

      assert Regex.match?(~r/<button[^>]*phx-click="issue_token"[^>]*disabled/s, html)
    end

    test "are on for an admin with the api permission", %{scope: scope} do
      html = render_section(%{phoenix_kit_current_scope: scope})

      refute Regex.match?(~r/<button[^>]*phx-click="issue_token"[^>]*disabled/s, html)
      refute html =~ "You need the API permission to issue a token."
    end

    test "are off with a hint for an admin without the api permission" do
      html = render_section(%{phoenix_kit_current_scope: scope_of(user_without_api())})

      assert Regex.match?(~r/<button[^>]*phx-click="issue_token"[^>]*disabled/s, html)
      assert html =~ "You need the API permission to issue a token."
    end

    test "asking before replacing a token that exists", %{scope: scope, admin: admin} do
      refute render_section(%{phoenix_kit_current_scope: scope}) =~
               "Issue a new token? The current"

      {_key, _token} = runner_key(admin)

      assert render_section(%{phoenix_kit_current_scope: scope}) =~
               "Issue a new token? The current token of the runner stops working."
    end
  end

  describe "translations" do
    setup do
      original = Gettext.get_locale(PhoenixKit.Modules.Emails.Gettext)
      on_exit(fn -> Gettext.put_locale(PhoenixKit.Modules.Emails.Gettext, original) end)
    end

    test "the section reads in Russian", %{scope: scope} do
      put_mode("runner")
      Gettext.put_locale(PhoenixKit.Modules.Emails.Gettext, "ru")

      html = render_section(%{phoenix_kit_current_scope: scope})

      assert html =~ "Проверка ящиков"
      assert html =~ "Раннер на вашем компьютере"
      assert html =~ "Выпустить новый токен"
      assert html =~ "Ещё не подключался"
      assert html =~ "Отправитель (MAIL FROM)"
      assert html =~ "Дополнительно"
      assert html =~ "10 адресов за сессию, пауза домена 10 с, повтор greylist 20 мин × 3"
    end

    test "the runner status reads \"На связи\" in Russian", %{admin: admin} do
      put_mode("runner")
      {key, _token} = runner_key(admin)
      heartbeat(key, 12)
      Gettext.put_locale(PhoenixKit.Modules.Emails.Gettext, "ru")

      html = render_section()

      assert html =~ "На связи · отклик"
      assert html =~ "WORKSTATION · порт 25 открыт · в очереди 0"
    end

    test "the built-in runner's status reads in Russian and in Estonian" do
      put_mode("local")
      Runners.heartbeat_local(%{name: "mailhost", port25: "open"}, DateTime.utc_now())

      Gettext.put_locale(PhoenixKit.Modules.Emails.Gettext, "ru")
      html = render_section()
      assert html =~ "Готов · mailhost · порт 25 открыт · в очереди 0"
      assert html =~ "имя в EHLO"

      Gettext.put_locale(PhoenixKit.Modules.Emails.Gettext, "et")
      html = render_section()
      assert html =~ "Valmis · mailhost"
      assert html =~ "EHLO nimi"
    end

    test "every message of the section is translated into Russian and Estonian" do
      for locale <- ["ru", "et"] do
        path = "priv/gettext/#{locale}/LC_MESSAGES/default.po"

        untranslated =
          path
          |> File.read!()
          |> String.split("\n\n")
          |> Enum.filter(&String.contains?(&1, "settings_sections/smtp_verification"))
          |> Enum.reject(
            &(Regex.match?(~r/^msgstr ".+"/m, &1) or Regex.match?(~r/^msgstr ""\n"/m, &1))
          )
          |> Enum.map(
            &(&1
              |> String.split("\n")
              |> Enum.find(fn l -> String.starts_with?(l, "msgid") end))
          )

        assert untranslated == [], "#{locale}: #{inspect(untranslated)}"

        refute File.read!(path)
               |> String.split("\n\n")
               |> Enum.any?(&(String.contains?(&1, "smtp_verification") and &1 =~ "fuzzy"))
      end
    end
  end

  ## --- Events ---

  describe "set_mode" do
    test "saves the mode" do
      socket = socket() |> event("set_mode", %{"mode" => "runner"})

      assert Config.smtp_mode_setting() == "runner"
      assert socket.assigns.mode == "runner"
      assert flash(socket, :info) =~ "through the runner"

      socket = socket |> event("set_mode", %{"mode" => "local"}) |> event("confirm_switch_local")
      assert Config.smtp_mode_setting() == "local"
      assert socket.assigns.mode == "local"
    end

    test "off settles the addresses that waited for SMTP and says so" do
      put_mode("runner")
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})
      {:ok, _} = Verification.verify("info@#{domain}", smtp: :enqueue)
      assert SmtpQueue.counts().queued == 1

      socket = socket() |> event("set_mode", %{"mode" => "off"})

      assert SmtpQueue.counts().queued == 0

      assert flash(socket, :info) =~
               "1 addresses that were waiting for it were settled without it"

      assert socket.assigns.mode == "off"
    end

    test "an unknown mode changes nothing" do
      put_mode("local")
      socket = socket() |> event("set_mode", %{"mode" => "bogus"})

      assert Config.smtp_mode_setting() == "local"
      assert flash(socket, :error) == "Failed to save the mode"
    end

    test "runner mode is refused on a core without the machine API" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      socket = socket() |> event("set_mode", %{"mode" => "runner"})

      assert Config.smtp_mode_setting() == "off"
      assert flash(socket, :error) =~ "needs the machine API of PhoenixKit 2.63"
    end
  end

  describe "switching to this server" do
    test "asks first and saves nothing until it is confirmed" do
      socket = socket() |> event("set_mode", %{"mode" => "local"})

      assert socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "off"
      assert socket.assigns.mode == "off"
      assert flash(socket, :info) == nil

      html = render_section(%{confirm_local?: true})
      assert html =~ "Check mailboxes from this server?"
      assert html =~ "go out from the IP address of the server this site runs on"
      assert html =~ "Do not enable it if other sites share this IP address"
      assert html =~ "tests whether its port 25 is open"
      assert html =~ ~s|phx-click="confirm_switch_local"|
      assert html =~ ~s|phx-click="cancel_switch_local"|
      assert html =~ "Switch to this server"

      socket = event(socket, "confirm_switch_local")

      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "local"
      assert socket.assigns.mode == "local"
      assert flash(socket, :info) =~ "from this server"
    end

    test "cancelling keeps the previous mode, also on the radio buttons" do
      put_mode("runner")
      socket = socket() |> event("set_mode", %{"mode" => "local"})

      html = render_section(%{confirm_local?: true})
      assert Regex.match?(~r/<input[^>]*value="local"[^>]*checked/s, html)

      socket = event(socket, "cancel_switch_local")

      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "runner"
      assert socket.assigns.mode == "runner"

      html = render_section()
      assert Regex.match?(~r/<input[^>]*value="runner"[^>]*checked/s, html)
      refute Regex.match?(~r/<input[^>]*value="local"[^>]*checked/s, html)
    end

    test "a confirmation nobody asked for does nothing" do
      socket = socket() |> event("confirm_switch_local")

      assert Config.smtp_mode_setting() == "off"
      assert flash(socket, :error) == "That action is not available."
    end

    test "choosing another mode while the question is open drops it" do
      socket =
        socket()
        |> event("set_mode", %{"mode" => "local"})
        |> event("set_mode", %{"mode" => "runner"})

      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "runner"

      socket = event(socket, "confirm_switch_local")
      assert Config.smtp_mode_setting() == "runner"
      assert flash(socket, :error) == "That action is not available."
    end

    test "off and runner need no confirmation" do
      put_mode("local")

      socket = socket() |> event("set_mode", %{"mode" => "off"})
      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "off"

      socket = event(socket, "set_mode", %{"mode" => "runner"})
      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "runner"
    end

    test "choosing local again while it is on asks nothing" do
      put_mode("local")
      socket = socket() |> event("set_mode", %{"mode" => "local"})

      refute socket.assigns.confirm_local?
      assert Config.smtp_mode_setting() == "local"
    end
  end

  describe "save" do
    test "writes the fields and shows what was stored" do
      params = %{
        "mail_from" => "verify@acme-mail.test",
        "helo" => "mx.acme-mail.test",
        "rcpt_per_session" => "20"
      }

      socket = socket() |> event("save", %{"smtp" => params})

      assert Config.smtp_mail_from() == {"verify@acme-mail.test", :override}
      assert Config.smtp_helo() == "mx.acme-mail.test"
      assert Config.rcpt_per_session() == 20
      assert socket.assigns.errors == %{}
      assert socket.assigns.form["rcpt_per_session"] == "20"
      assert flash(socket, :info) == "Settings saved"
    end

    test "an invalid field is reported next to the field and nothing is written" do
      put_mode("runner")

      socket =
        socket()
        |> event("save", %{
          "smtp" => %{
            "mail_from" => "nope",
            "domain_interval_s" => "0",
            "helo" => "ok.acme-mail.test"
          }
        })

      assert flash(socket, :error) == "Some fields are not valid"
      assert Config.smtp_helo() == nil

      assert socket.assigns.error_messages["mail_from"] =~ "Not a usable sender address"
      assert socket.assigns.error_messages["domain_interval_s"] == "A whole number above zero."
      assert socket.assigns.form["mail_from"] == "nope"
      assert socket.assigns.advanced_open?

      html = render_section(%{form: socket.assigns.form, errors: socket.assigns.errors})
      assert html =~ "Not a usable sender address"
      assert html =~ "A whole number above zero."
      assert html =~ "nope"
    end

    test "a crafted payload cannot break the form" do
      put_mode("local")

      socket =
        socket()
        |> event("save", %{"smtp" => %{"rcpt_per_session" => %{"a" => 1}, "mail_from" => "x"}})

      assert socket.assigns.form["rcpt_per_session"] == "10"

      assert render_section(%{form: socket.assigns.form, errors: socket.assigns.errors}) =~
               "smtp[rcpt_per_session]"
    end

    test "an error in the sender alone leaves the advanced block closed" do
      socket = socket() |> event("save", %{"smtp" => %{"mail_from" => "nope"}})

      refute socket.assigns.advanced_open?
    end

    test "an invalid save keeps only the fields of the form" do
      socket =
        socket()
        |> event("save", %{
          "smtp" => %{"mail_from" => "nope", "evil" => String.duplicate("x", 1000)}
        })

      refute Map.has_key?(socket.assigns.form, "evil")
      assert socket.assigns.form["mail_from"] == "nope"
    end

    test "saving the form as it was shown stores nothing: the defaults are not frozen" do
      put_mode("local")
      form = socket().assigns.form

      socket = event(socket(), "save", %{"smtp" => form})

      assert flash(socket, :info) == "Settings saved"
      assert Settings.get_setting("email_verify_rcpt_per_session") == nil
      assert Settings.get_setting("email_verify_domain_interval_s") == nil
      assert Settings.get_setting("email_verify_smtp_helo") == nil
    end

    test "only the changed field is written" do
      put_mode("local")
      form = Map.put(socket().assigns.form, "rcpt_per_session", "20")

      event(socket(), "save", %{"smtp" => form})

      assert Settings.get_setting("email_verify_rcpt_per_session") == "20"
      assert Settings.get_setting("email_verify_grey_retry_minutes") == nil
    end

    test "it is recorded who changed the sender", %{scope: scope, admin: admin} do
      put_mode("local")
      socket = socket(%{phoenix_kit_current_scope: scope})

      event(socket, "save", %{"smtp" => %{"mail_from" => "verify@acme-mail.test"}})

      assert [latest | _] = History.list("email_verify_smtp_mail_from")
      assert latest.actor_uuid == admin.uuid
    end

    test "a store that refuses is reported on the form" do
      put_mode("local")

      html = render_section(%{errors: %{"base" => :not_saved}})

      assert html =~ "The settings could not be saved."
    end

    test "the mode is not part of the form" do
      put_mode("local")
      _socket = socket() |> event("save", %{"smtp" => %{"mail_from" => "verify@acme-mail.test"}})

      assert Config.smtp_mode_setting() == "local"
    end
  end

  describe "validate and the Advanced block" do
    setup do
      put_mode("local")
      :ok
    end

    test "what is typed is kept in the form, not written", %{} do
      socket =
        socket()
        |> event("validate", %{
          "_target" => ["smtp", "mail_from"],
          "smtp" => %{"mail_from" => "verify@acme-mail.test", "rcpt_per_session" => "7"}
        })

      assert socket.assigns.form["mail_from"] == "verify@acme-mail.test"
      assert socket.assigns.form["rcpt_per_session"] == "7"
      assert Config.smtp_mail_from() == {"mail@acme-mail.test", :site_sender}
      assert Config.rcpt_per_session() == 10
    end

    test "unknown or non-text fields are not kept" do
      socket =
        socket()
        |> event("validate", %{
          "smtp" => %{"evil" => "x", "helo" => %{"a" => 1}, "grey_max_attempts" => "4"}
        })

      refute Map.has_key?(socket.assigns.form, "evil")
      assert socket.assigns.form["helo"] == ""
      assert socket.assigns.form["grey_max_attempts"] == "4"
    end

    test "the block opens and shuts on the server" do
      socket = socket()
      refute socket.assigns.advanced_open?

      socket = event(socket, "toggle_advanced")
      assert socket.assigns.advanced_open?

      html = render_section(%{advanced_open?: true})
      assert html =~ ~s|aria-expanded="true"|
      refute html =~ ~r/id="smtp-verification-advanced"[^>]*class="[^"]*hidden/

      refute event(socket, "toggle_advanced").assigns.advanced_open?
    end

    test "is not a <details>, whose open state a patch would reset" do
      html = render_section()

      refute html =~ "<details"
      assert html =~ ~s|aria-expanded="false"|
      assert html =~ ~r/id="smtp-verification-advanced"[^>]*class="[^"]*hidden/
    end

    test "tells the least time to finish a session and why" do
      html = render_section()

      assert html =~ ~s|id="smtp-verification-lease-hint"|
      assert html =~ "A session can run up to 240 s"
      assert html =~ "cannot be below 300 s"
    end

    test "a lease below the floor is an error on its own field, in the Advanced block" do
      socket = event(socket(), "save", %{"smtp" => %{"smtp_lease_s" => "120"}})

      assert socket.assigns.advanced_open?
      assert socket.assigns.errors == %{"smtp_lease_s" => {:min, 300}}
      assert flash(socket, :error) == "Some fields are not valid"
      assert Settings.get_setting("email_verify_smtp_lease_s") == nil

      html = render_section(%{errors: socket.assigns.errors, form: socket.assigns.form})
      assert html =~ "At least 300."
    end

    test "an error in the numbers opens it and a later save does not shut it" do
      socket = event(socket(), "save", %{"smtp" => %{"smtp_lease_s" => "0"}})
      assert socket.assigns.advanced_open?

      socket = event(socket, "save", %{"smtp" => %{"mail_from" => "nope"}})
      assert socket.assigns.advanced_open?
    end

    test "the form is wired to validate and the hints are tied to their fields" do
      html = render_section()

      assert html =~ ~s|phx-change="validate"|
      assert html =~ ~s|aria-describedby="smtp-verification-mail-from-hint"|
      assert html =~ ~s|id="smtp-verification-mail-from-hint"|
      assert html =~ ~s|aria-describedby="smtp-verification-helo-hint"|
      assert html =~ ~s|id="smtp-verification-helo-hint"|
    end
  end

  describe "issue_token" do
    setup %{scope: scope} do
      put_mode("runner")
      %{socket: socket(%{phoenix_kit_current_scope: scope})}
    end

    test "creates a key with exactly the runner scope and shows the token once", %{
      socket: socket,
      admin: admin
    } do
      socket = event(socket, "issue_token")

      assert %{token: token, command: command, env_command: env_command, key_name: name} =
               socket.assigns.new_token

      assert token =~ ~r/\Apk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}\z/
      assert command =~ "-Token #{token}"
      assert env_command =~ "$env:PK_SMTP_RUNNER_TOKEN='#{token}'"
      assert env_command =~ "-Server #{RunnerSetup.server_url()}"
      refute env_command =~ "-Token"
      assert command =~ "-Server #{RunnerSetup.server_url()}"
      assert command =~ "pk-smtp-runner.ps1"
      assert name =~ ~r/\ASMTP runner \(\d{4}-\d{2}-\d{2}\)\z/

      assert [key] = live_keys()
      assert key.scopes == ["emails.smtp_runner:run"]
      assert key.user_uuid == admin.uuid
      assert key.name == name
      assert key.expires_at == nil

      html = render_section(%{new_token: socket.assigns.new_token, loaded?: false})
      assert html =~ token
      assert html =~ "The token is shown once"
      assert html =~ ~s|phx-hook="CopyToClipboard"|
      assert html =~ "Command for PowerShell"
      assert html =~ "Or pass the token on the command line"
      assert html =~ "$env:PK_SMTP_RUNNER_TOKEN=&#39;#{token}&#39;"

      # The environment-variable form comes first, the -Token form below it.
      {env_at, _} = :binary.match(html, "-new-env-command")
      {cmd_at, _} = :binary.match(html, ~s|-new-command"|)
      assert env_at < cmd_at
    end

    test "the instruction of a runner that is not yet connected names the environment variable",
         %{
           scope: scope
         } do
      html = render_section(%{phoenix_kit_current_scope: scope})

      assert html =~ "-Token &lt;token&gt;"
      assert html =~ "Or pass the token on the command line"

      # The environment-variable form is shown first, the -Token form below it.
      {env_at, _} = :binary.match(html, "PK_SMTP_RUNNER_TOKEN")
      {token_at, _} = :binary.match(html, "-Token &lt;token&gt;")
      assert env_at < token_at
    end

    test "the token is not kept anywhere once it is dismissed", %{socket: socket} do
      socket = event(socket, "issue_token")
      %{token: token} = socket.assigns.new_token

      socket = event(socket, "dismiss_token")

      assert socket.assigns.new_token == nil
      refute inspect(socket.assigns.status) =~ token
      refute render_section() =~ token
      refute inspect(Repo.all(Key)) =~ token
    end

    test "the token works against the runner tools", %{socket: socket} do
      socket = event(socket, "issue_token")

      conn =
        request(socket.assigns.new_token.token, "emails.claim_smtp_jobs", %{"max_sessions" => 0})

      assert conn.status == 200
    end

    test "a new token revokes the previous one: one runner per site", %{socket: socket} do
      socket = event(socket, "issue_token")
      %{token: first_token} = socket.assigns.new_token
      socket = socket |> event("dismiss_token") |> event("issue_token")

      assert [_only] = live_keys()
      assert socket.assigns.new_token.revoked == 1
      assert request(first_token, "emails.claim_smtp_jobs", %{"max_sessions" => 0}).status == 401

      html = render_section(%{new_token: socket.assigns.new_token})
      assert html =~ "The previous token was revoked"
    end

    test "while a token is on the screen no second one is issued", %{socket: socket} do
      socket = event(socket, "issue_token")
      socket = event(socket, "issue_token")

      assert length(live_keys()) == 1
      assert flash(socket, :error) == "That action is not available."
    end

    test "an admin without the api permission gets no key", %{scope: _scope} do
      socket = socket(%{phoenix_kit_current_scope: scope_of(user_without_api())})

      socket = event(socket, "issue_token")

      assert live_keys() == []
      assert socket.assigns.new_token == nil
      assert flash(socket, :error) == "You are not allowed to do that."
    end

    test "nobody is known: no key" do
      socket = event(socket(), "issue_token")

      assert live_keys() == []
      assert flash(socket, :error) == "You are not allowed to do that."
    end

    test "rights lost since the page was opened are read again", %{socket: socket, role: role} do
      :ok = Permissions.revoke_permission(role.uuid, "api")

      socket = event(socket, "issue_token")

      assert live_keys() == []
      assert flash(socket, :error) == "You are not allowed to do that."
    end

    test "an admin who cannot hold the scope is told why" do
      {user, role} = user_with(["emails"])
      :ok = Permissions.revoke_permission(role.uuid, "emails")
      socket = socket(%{phoenix_kit_current_scope: scope_of(user)})

      socket = event(socket, "issue_token")

      assert live_keys() == []
      assert flash(socket, :error) =~ "needs the \"emails\" permission"
    end

    test "a core without the machine API issues nothing", %{socket: socket} do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      socket = event(socket, "issue_token")

      assert Repo.all(Key) == []

      assert flash(socket, :error) ==
               "The runner needs the machine API of PhoenixKit 2.63 or newer."
    end
  end

  describe "revoke_token" do
    test "revokes the runner token at once", %{scope: scope, admin: admin} do
      put_mode("runner")
      {key, token} = runner_key(admin)
      socket = socket(%{phoenix_kit_current_scope: scope})

      socket = event(socket, "revoke_token")

      assert Keys.dead_reason(Repo.get!(Key, key.uuid)) == :revoked
      assert request(token, "emails.claim_smtp_jobs", %{"max_sessions" => 0}).status == 401
      assert flash(socket, :info) == "Token revoked"
    end

    test "says so when there is nothing to revoke", %{scope: scope} do
      socket = event(socket(%{phoenix_kit_current_scope: scope}), "revoke_token")

      assert flash(socket, :info) == "There was no active token to revoke"
    end

    test "a token of another admin stays and the count says so", %{scope: scope} do
      {other, _role} = user_with(["emails"])
      {key, _token} = runner_key(other)

      socket = event(socket(%{phoenix_kit_current_scope: scope}), "revoke_token")

      assert Keys.dead_reason(Repo.get!(Key, key.uuid)) == nil
      assert flash(socket, :info) =~ "belongs to another admin and was not revoked"
    end

    test "an admin without the api permission revokes nothing", %{admin: admin} do
      {key, _token} = runner_key(admin)
      socket = socket(%{phoenix_kit_current_scope: scope_of(user_without_api())})

      socket = event(socket, "revoke_token")

      assert Keys.dead_reason(Repo.get!(Key, key.uuid)) == nil
      assert flash(socket, :error) == "You are not allowed to do that."
    end
  end

  describe "clear_pause" do
    test "lifts the pause of the runner", %{admin: admin} do
      put_mode("runner")
      {key, _token} = runner_key(admin)
      runner = heartbeat(key, 5)

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [paused_until: DateTime.add(DateTime.utc_now(), 3600), pause_reason: "x"]
      )

      socket = socket()
      assert socket.assigns.view.paused

      socket = event(socket, "clear_pause")

      assert socket.assigns.view.paused == nil
      assert Verification.runner_status().paused == nil
      assert flash(socket, :info) == "The runner is no longer paused"
    end
  end

  describe "enabling the machine API" do
    setup %{scope: scope} do
      put_mode("runner")
      put_setting("api_admin_enabled", "false")
      %{socket: socket(%{phoenix_kit_current_scope: scope})}
    end

    test "asks first and enables only after the confirmation", %{socket: socket} do
      socket = event(socket, "request_enable_api")

      assert socket.assigns.confirm_api?
      refute Settings.get_boolean_setting("api_admin_enabled", false)

      html = render_section(%{confirm_api?: true})
      assert html =~ "Enable the machine API?"
      assert html =~ "any API key with a suitable scope can call it"
      assert html =~ ~s|phx-click="confirm_enable_api"|
      assert html =~ ~s|phx-click="cancel_enable_api"|

      socket = event(socket, "confirm_enable_api")

      assert Settings.get_boolean_setting("api_admin_enabled", false)
      assert socket.assigns.preconditions == []
      refute socket.assigns.confirm_api?
      assert flash(socket, :info) == "The machine API is on"
    end

    test "cancelling leaves it off", %{socket: socket} do
      socket = socket |> event("request_enable_api") |> event("cancel_enable_api")

      refute socket.assigns.confirm_api?
      refute Settings.get_boolean_setting("api_admin_enabled", false)
    end

    test "a confirmation nobody asked for does nothing", %{socket: socket} do
      socket = event(socket, "confirm_enable_api")

      refute Settings.get_boolean_setting("api_admin_enabled", false)
      assert flash(socket, :error) == "That action is not available."
    end

    test "an admin without the api permission cannot even ask" do
      socket = socket(%{phoenix_kit_current_scope: scope_of(user_without_api())})

      socket = socket |> event("request_enable_api") |> event("confirm_enable_api")

      refute socket.assigns.confirm_api?
      refute Settings.get_boolean_setting("api_admin_enabled", false)
    end

    test "it is recorded who switched it on", %{socket: socket, admin: admin} do
      socket |> event("request_enable_api") |> event("confirm_enable_api")

      assert [latest | _] = History.list("api_admin_enabled")
      assert latest.actor_uuid == admin.uuid
    end

    test "nothing to enable when it is already on", %{socket: socket} do
      put_setting("api_admin_enabled", "true")
      socket = socket |> reload_preconditions() |> event("request_enable_api")

      refute socket.assigns.confirm_api?
    end
  end

  defp reload_preconditions(socket) do
    {:ok, socket} =
      SmtpVerification.update(%{id: "smtp-verification", relay_event: :runner}, socket)

    socket
  end

  ## --- Live updates ---

  describe "relay events" do
    setup do
      put_mode("runner")
      :ok
    end

    test "a tick moves the clock without reading the status", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 10)
      socket = socket()
      status = socket.assigns.status

      old = DateTime.add(DateTime.utc_now(), -3600)
      socket = %{socket | assigns: %{socket.assigns | now: old}}

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, socket)

      assert socket.assigns.status == status
      assert DateTime.compare(socket.assigns.now, old) == :gt
    end

    test "an announcement reads the status again", %{admin: admin} do
      socket = socket()
      assert socket.assigns.view.state == :never

      {key, _token} = runner_key(admin)
      heartbeat(key, 1)

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :runner}, socket)

      assert socket.assigns.view.state == :online
    end

    test "the \"N s ago\" text moves with the clock, the status is not read", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)
      socket = socket()
      assert Enum.join(socket.assigns.view.segments, " ") =~ "answered 5 s ago"

      # The row is not read again on a tick: only the clock, so a last contact that is
      # older in the section's data reads older.
      runner = %{
        socket.assigns.status.runner
        | last_seen_at: DateTime.add(DateTime.utc_now(), -200)
      }

      status = %{socket.assigns.status | runner: runner}
      socket = %{socket | assigns: %{socket.assigns | status: status, idle_poll_s: 300}}

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, socket)

      assert Enum.join(socket.assigns.view.segments, " ") =~ "answered 3 min ago"
    end

    test "a runner that stops calling turns offline by the clock alone", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 40)
      socket = socket()
      assert socket.assigns.view.state == :online

      socket = %{socket | assigns: %{socket.assigns | idle_poll_s: 10}}

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, socket)

      assert socket.assigns.view.state == :offline
      assert Enum.join(socket.assigns.view.segments, " ") =~ "Offline"
    end

    test "a pause that has ended is gone on the next tick", %{admin: admin} do
      {key, _token} = runner_key(admin)
      runner = heartbeat(key, 5)

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [paused_until: DateTime.add(DateTime.utc_now(), 60), pause_reason: "x"]
      )

      socket = socket()
      assert socket.assigns.view.paused

      # The row is not read again on a tick: the pause it held has run out by the clock.
      ended = %{socket.assigns.status.paused | until: DateTime.add(DateTime.utc_now(), -1)}
      status = %{socket.assigns.status | paused: ended}
      socket = %{socket | assigns: %{socket.assigns | status: status}}

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, socket)

      assert socket.assigns.view.paused == nil
    end

    test "only the state is a live region, not the clock", %{admin: admin} do
      {key, _token} = runner_key(admin)
      heartbeat(key, 5)

      html = render_section()

      assert html =~
               ~r/<span class="sr-only" role="status" aria-live="polite">\s*Online\s*<\/span>/

      assert length(Regex.scan(~r/aria-live/, html)) == 1
    end

    test "the status is read again on every twelfth tick", %{admin: admin} do
      socket = socket()
      assert socket.assigns.view.state == :never
      {key, _token} = runner_key(admin)
      heartbeat(key, 1)

      socket =
        Enum.reduce(1..12, socket, fn _n, acc ->
          {:ok, acc} =
            SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, acc)

          acc
        end)

      assert socket.assigns.view.state == :online
    end

    test "ticks do nothing while the mode is not runner" do
      put_mode("off")
      socket = socket()
      before = socket.assigns.now

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: :tick}, socket)

      assert socket.assigns.now == before
    end

    test "an admin passed by the host after the first render is picked up", %{scope: scope} do
      socket = socket()
      refute socket.assigns.can_api?

      {:ok, socket} =
        SmtpVerification.update(
          %{id: "smtp-verification", phoenix_kit_current_scope: scope},
          socket
        )

      assert socket.assigns.scope_state == :known
      assert socket.assigns.can_api?
    end

    test "the admin found by the relay arrives as an event", %{scope: scope} do
      socket = socket()
      assert socket.assigns.scope_state == :pending
      refute socket.assigns.can_api?

      {:ok, socket} =
        SmtpVerification.update(
          %{id: "smtp-verification", relay_event: {:scope, scope}},
          socket
        )

      assert socket.assigns.scope_state == :known
      assert socket.assigns.can_api?

      {:ok, socket} =
        SmtpVerification.update(%{id: "smtp-verification", relay_event: {:scope, nil}}, socket)

      assert socket.assigns.scope_state == :unknown
      refute socket.assigns.can_api?

      assert render_section(%{
               phoenix_kit_current_scope: nil,
               scope_state: :unknown
             }) =~ "Issue a key with the scope emails.smtp_runner:run in Settings → API."
    end
  end

  describe "Relay" do
    test "reads the admin out of the page's state" do
      scope = scope_of(elem(user_with(["emails"]), 0))

      {:ok, view} =
        Agent.start_link(fn -> %{socket: %{assigns: %{phoenix_kit_current_scope: scope}}} end)

      assert Relay.scope_of(view) == scope
    end

    test "is nil when the state has no scope or is not a page's" do
      {:ok, bare} = Agent.start_link(fn -> %{socket: %{assigns: %{}}} end)
      {:ok, other} = Agent.start_link(fn -> :something_else end)

      assert Relay.scope_of(bare) == nil
      assert Relay.scope_of(other) == nil
    end

    test "is nil for a process that does not answer" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      assert Relay.scope_of(pid, attempts: 2, timeout: 30, backoff_ms: 5) == nil
    end

    test "asks again when the page was busy the first time" do
      scope = scope_of(elem(user_with(["emails"]), 0))

      {:ok, view} =
        Agent.start_link(fn -> %{socket: %{assigns: %{phoenix_kit_current_scope: scope}}} end)

      Agent.cast(view, fn state ->
        Process.sleep(60)
        state
      end)

      assert Relay.scope_of(view, attempts: 1, timeout: 20, backoff_ms: 5) == nil
      assert Relay.scope_of(view, attempts: 3, timeout: 100, backoff_ms: 5) == scope
    end

    test "stop ends a relay, and a relay that is gone is not an error" do
      {:ok, relay} = Relay.start(self(), SmtpVerification, "smtp-verification", false)
      ref = Process.monitor(relay)

      assert Relay.stop(relay) == :ok
      assert_receive {:DOWN, ^ref, :process, ^relay, _}, 1_000
      assert Relay.stop(relay) == :ok
    end

    test "turns a runner announcement into an update of the section" do
      {:ok, relay} = Relay.start(self(), SmtpVerification, "smtp-verification", false)
      on_exit(fn -> if Process.alive?(relay), do: Process.exit(relay, :kill) end)

      Runners.broadcast(%{event: :heartbeat, runner_uuid: "x"})

      assert_receive {:phoenix, :send_update,
                      {{SmtpVerification, "smtp-verification"},
                       %{id: "smtp-verification", relay_event: :runner}}},
                     1_000
    end

    test "ticks" do
      {:ok, relay} = Relay.start(self(), SmtpVerification, "smtp-verification", false, 20)
      on_exit(fn -> if Process.alive?(relay), do: Process.exit(relay, :kill) end)

      assert_receive {:phoenix, :send_update, {_, %{relay_event: :tick}}}, 1_000
    end

    test "stops with the page" do
      view = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, relay} = Relay.start(view, SmtpVerification, "smtp-verification", false)
      ref = Process.monitor(relay)

      Process.exit(view, :kill)

      assert_receive {:DOWN, ^ref, :process, ^relay, :normal}, 1_000
    end
  end
end
