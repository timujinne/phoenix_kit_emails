defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification do
  @moduledoc """
  "Mailbox verification (SMTP)" section on the core Email Sending settings page
  (`/admin/settings/email-sending`), contributed via
  `c:PhoenixKit.Module.email_settings_sections/0`.

  One card: who opens the SMTP connections (off, this server, or a runner on the
  user's own machine), and for a runner its state (online, offline, never connected,
  paused), whose API key it works with, the buttons to issue and revoke its token, the
  four-line instruction, what must be switched on in core first, the `MAIL FROM` and
  `HELO` fields and a collapsed block with the numbers. See
  `docs/superpowers/specs/2026-10-20-smtp-runner.md`, section 6.

  ## Who is looking

  Core renders a section with nothing but its `id`, so the signed-in admin is not among
  the assigns. The section takes `:phoenix_kit_current_scope` when a host passes it;
  otherwise the first connected render has `SmtpVerification.Relay` read it from the
  page process. Until it is known (or when it cannot be read) the token buttons stay
  off, and every action that needs a person's rights reads their rights again first
  (`PhoenixKit.API.Access.fresh_scope/1`), as Settings -> API does.

  ## Live updates

  The relay process subscribes to the runner topic and sends `relay_event: :runner`
  when the runner changes (the status is read again) and `relay_event: :tick` every few
  seconds (only the clock moves; the status is read again about once a minute).
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Modules.Emails.Paths
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.RunnerKeys
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.RunnerSetup
  alias PhoenixKit.Modules.Emails.Verification.SmtpSettings
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification.Relay
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  # The status is read again on every Nth tick, in case an announcement was missed.
  @reload_every 12

  @impl true
  def update(%{relay_event: event}, socket), do: {:ok, relay_event(event, socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:loaded?],
        do: refresh_scope(socket, assigns),
        else: socket |> load() |> start_relay()

    {:ok, socket}
  end

  # A host that passes the signed-in admin later than the first render.
  defp refresh_scope(socket, %{phoenix_kit_current_scope: scope}) do
    relay_event({:scope, scope}, socket)
  end

  defp refresh_scope(socket, _assigns), do: socket

  ## --- Loading ---

  defp load(socket) do
    current = SmtpSettings.current()

    socket
    |> assign(:loaded?, true)
    |> assign(:ticks, 0)
    |> assign(:relay, nil)
    |> assign_new(:phoenix_kit_current_scope, fn -> nil end)
    |> assign_new(:scope_state, fn assigns -> scope_state(assigns.phoenix_kit_current_scope) end)
    |> assign_new(:new_token, fn -> nil end)
    |> assign_new(:confirm_api?, fn -> false end)
    |> assign_new(:form, fn -> form_params(current) end)
    |> assign_new(:errors, fn -> %{} end)
    |> assign_new(:advanced_open?, fn -> false end)
    |> assign(:site_url, site_url())
    |> assign(:script_path, Paths.runner_script())
    |> assign(:api_settings_path, "/admin/settings/api")
    |> reload()
  end

  defp scope_state(%Scope{}), do: :known
  defp scope_state(_scope), do: :pending

  defp start_relay(socket) do
    if connected?(socket) do
      fetch? = socket.assigns.scope_state == :pending
      {:ok, relay} = Relay.start(self(), __MODULE__, socket.assigns.id, fetch?)
      assign(socket, :relay, relay)
    else
      socket
    end
  end

  # Everything that comes from the database. `view` is what the template shows; it is
  # computed again on every tick from the same data, so the clock moves without a read.
  defp reload(socket) do
    status = Verification.runner_status()

    socket
    |> assign(:status, status)
    |> assign(:idle_poll_s, Config.idle_poll_s())
    |> assign(:site_sender, Config.site_sender_address())
    |> assign(:preconditions, RunnerSetup.preconditions())
    |> assign(:active_keys, active_keys())
    |> assign(:now, UtilsDate.utc_now())
    |> assign_view()
  end

  defp active_keys do
    if Config.machine_api_available?(), do: length(RunnerKeys.active()), else: 0
  rescue
    _ -> 0
  end

  defp site_url do
    Routes.base_url()
  rescue
    _ -> ""
  end

  defp relay_event(:runner, socket), do: reload(socket)

  defp relay_event(:tick, %{assigns: %{ticks: ticks}} = socket) do
    cond do
      socket.assigns.mode != "runner" ->
        socket

      rem(ticks + 1, @reload_every) == 0 ->
        socket |> assign(:ticks, ticks + 1) |> reload()

      true ->
        socket |> assign(:ticks, ticks + 1) |> assign(:now, UtilsDate.utc_now()) |> assign_view()
    end
  end

  defp relay_event({:scope, scope}, socket) do
    socket
    |> assign(:phoenix_kit_current_scope, scope)
    |> assign(:scope_state, if(match?(%Scope{}, scope), do: :known, else: :unknown))
    |> assign_view()
  end

  defp relay_event(_event, socket), do: socket

  ## --- The view ---

  defp assign_view(socket) do
    %{status: status, now: now} = socket.assigns
    scope = socket.assigns.phoenix_kit_current_scope

    socket
    |> assign(:mode, status.mode)
    |> assign(:api_unavailable?, not status.api_available)
    |> assign(:view, build_view(status, now, socket.assigns.idle_poll_s))
    |> assign(:can_api?, can_api?(scope))
    |> assign(:number_inputs, number_inputs(socket.assigns.form, socket.assigns.errors))
    |> assign(:error_messages, error_messages(socket.assigns.errors))
    |> assign(:advanced_summary, advanced_summary(socket.assigns.form))
  end

  defp can_api?(%Scope{} = scope), do: Scope.can?(scope, "api")
  defp can_api?(_scope), do: false

  defp build_view(status, now, idle_poll_s) do
    runner = status.runner
    online? = runner != nil and Runners.online?(runner.last_seen_at, now, idle_poll_s)

    state =
      cond do
        runner == nil or runner.last_seen_at == nil -> :never
        online? -> :online
        true -> :offline
      end

    %{
      state: state,
      paused: paused_view(status.paused),
      dot: dot_class(state, status.paused),
      segments: segments(state, runner, status, now),
      port25_blocked?: status.port25_blocked,
      mail_from: status.mail_from,
      mail_from_source: status.mail_from_source,
      mail_from_missing?: status.mail_from_missing,
      owner: owner_view(status.owner)
    }
  end

  defp paused_view(nil), do: nil
  defp paused_view(%{reason: reason}), do: %{reason: reason || gettext("no reason recorded")}

  defp dot_class(_state, %{}), do: "bg-warning"
  defp dot_class(:online, nil), do: "bg-success"
  defp dot_class(:offline, nil), do: "bg-warning"
  defp dot_class(:never, nil), do: "bg-base-content/30"

  defp segments(:never, _runner, status, _now) do
    [gettext("Not connected yet"), queue_text(status.queue)]
  end

  defp segments(:online, runner, status, now) do
    [
      pgettext("smtp runner status", "Online"),
      gettext("answered %{ago}", ago: ago(runner.last_seen_at, now)),
      runner.name,
      port25_text(runner.port25),
      queue_text(status.queue)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp segments(:offline, runner, status, _now) do
    [
      pgettext("smtp runner status", "Offline"),
      gettext("last seen %{at}", at: Calendar.strftime(runner.last_seen_at, "%d.%m %H:%M UTC")),
      runner.name,
      port25_text(runner.port25),
      queue_text(status.queue)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp port25_text("open"), do: gettext("port 25 open")
  defp port25_text("blocked"), do: gettext("port 25 closed")
  defp port25_text(_unknown), do: nil

  defp queue_text(%{queued: queued, leased: leased}) do
    gettext("%{n} in the queue", n: queued + leased)
  end

  defp ago(seen, now) do
    case max(DateTime.diff(now, seen, :second), 0) do
      seconds when seconds < 90 -> gettext("%{n} s ago", n: seconds)
      seconds -> gettext("%{n} min ago", n: div(seconds, 60))
    end
  end

  defp owner_view(nil), do: nil

  defp owner_view(owner) do
    who =
      case owner.name do
        name when name in [nil, ""] -> owner.email
        name -> "#{name} (#{owner.email})"
      end

    %{who: who, key_name: owner.key_name, warning: owner_warning(owner.warning, who)}
  end

  defp owner_warning(nil, _who), do: nil

  defp owner_warning(:owner_inactive, who),
    do:
      gettext(
        "The runner will stop: the owner of its key, %{who}, is deactivated. Issue a new token.",
        who: who
      )

  defp owner_warning(:no_emails_permission, who),
    do:
      gettext(
        "The runner will stop: the owner of its key, %{who}, no longer has the \"emails\" permission. Issue a new token.",
        who: who
      )

  defp owner_warning(:key_revoked, _who),
    do: gettext("The runner's token was revoked, so the runner has stopped. Issue a new token.")

  defp owner_warning(:key_expired, _who),
    do: gettext("The runner's token has expired, so the runner has stopped. Issue a new token.")

  ## --- The form ---

  defp form_params(current) do
    %{
      "mail_from" => current.mail_from,
      "helo" => current.helo,
      "selftest_host" => current.selftest_host
    }
    |> Map.merge(Map.new(current.numbers, fn {field, value} -> {field, to_string(value)} end))
  end

  defp number_inputs(form, errors) do
    for field <- SmtpSettings.number_fields() do
      %{
        field: field,
        label: number_label(field),
        value: Map.get(form, field, ""),
        error: errors |> Map.get(field) |> error_text(field)
      }
    end
  end

  defp number_label("rcpt_per_session"), do: gettext("Addresses per session")
  defp number_label("domain_interval_s"), do: gettext("Pause between sessions to a domain, s")
  defp number_label("grey_retry_minutes"), do: gettext("Greylist retry, min")
  defp number_label("grey_max_attempts"), do: gettext("Greylist attempts")
  defp number_label("smtp_lease_s"), do: gettext("Time to finish a session, s")
  defp number_label("smtp_max_attempts"), do: gettext("Lost sessions before giving up")
  defp number_label("smtp_connect_timeout_s"), do: gettext("Connect timeout, s")
  defp number_label("smtp_read_timeout_s"), do: gettext("Read timeout, s")
  defp number_label("smtp_idle_poll_s"), do: gettext("Runner poll when idle, s")
  defp number_label("domain_block_threshold"), do: gettext("Blocks that pause a domain")
  defp number_label("domain_block_window_min"), do: gettext("Window for those blocks, min")
  defp number_label("domain_pause_min"), do: gettext("Domain pause, min")
  defp number_label("runner_fail_sessions"), do: gettext("Failed sessions that pause the runner")
  defp number_label("runner_fail_domains"), do: gettext("Domains those sessions must span")
  defp number_label("runner_pause_min"), do: gettext("Runner pause, min")

  defp error_messages(errors) do
    Map.new(errors, fn {field, reason} -> {field, error_text(reason, field)} end)
  end

  defp error_text(nil, _field), do: nil

  defp error_text(:address, _field),
    do:
      gettext(
        "Not a usable sender address (an address on example.com or localhost does not count)."
      )

  defp error_text(:helo, _field),
    do: gettext("Letters, digits, hyphens and dots only (or an address like [203.0.113.9]).")

  defp error_text(:integer, _field), do: gettext("A whole number above zero.")
  defp error_text({:max, max}, _field), do: gettext("At most %{max}.", max: max)
  defp error_text(:not_saved, _field), do: gettext("The settings could not be saved.")

  defp advanced_summary(form) do
    gettext(
      "%{rcpt} addresses per session, %{interval} s between sessions to a domain, greylist retry %{retry} min × %{attempts}",
      rcpt: form["rcpt_per_session"],
      interval: form["domain_interval_s"],
      retry: form["grey_retry_minutes"],
      attempts: form["grey_max_attempts"]
    )
  end

  ## --- Events ---

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    case SmtpSettings.save_mode(mode) do
      {:ok, %{mode: mode, drained: drained}} ->
        {:noreply, socket |> reload() |> put_flash(:info, mode_message(mode, drained))}

      {:error, :runner_unavailable} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(
           :error,
           gettext("The runner needs the machine API of PhoenixKit 2.63 or newer.")
         )}

      {:error, _reason} ->
        {:noreply, socket |> reload() |> put_flash(:error, gettext("Failed to save the mode"))}
    end
  end

  def handle_event("save", %{"smtp" => params}, socket) when is_map(params) do
    case SmtpSettings.save(params) do
      {:ok, current} ->
        {:noreply,
         socket
         |> assign(:form, form_params(current))
         |> assign(:errors, %{})
         |> reload()
         |> put_flash(:info, gettext("Settings saved"))}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(
           :form,
           Map.merge(socket.assigns.form, Map.filter(params, &is_binary(elem(&1, 1))))
         )
         |> assign(:errors, errors)
         |> assign(:advanced_open?, Enum.any?(errors, fn {field, _} -> advanced?(field) end))
         |> assign_view()
         |> put_flash(:error, gettext("Some fields are not valid"))}
    end
  end

  def handle_event("clear_pause", _params, socket) do
    {:ok, _count} = Verification.clear_runner_pause()
    {:noreply, socket |> reload() |> put_flash(:info, gettext("The runner is no longer paused"))}
  end

  def handle_event("issue_token", _params, %{assigns: %{new_token: nil}} = socket) do
    with_api_access(socket, fn socket, scope -> issue_token(socket, scope) end)
  end

  def handle_event("issue_token", _params, socket), do: {:noreply, refuse(socket)}

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, :new_token, nil)}

  def handle_event("revoke_token", _params, socket) do
    with_api_access(socket, fn socket, scope ->
      case RunnerKeys.revoke(scope) do
        {:ok, %{revoked: 0, left: 0}} ->
          put_flash(socket, :info, gettext("There was no active token to revoke"))

        {:ok, %{revoked: revoked, left: left}} ->
          socket |> reload() |> put_flash(:info, revoked_message(revoked, left))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("The token could not be revoked"))
      end
    end)
  end

  def handle_event("request_enable_api", _params, socket) do
    if :api_admin_disabled in socket.assigns.preconditions and socket.assigns.can_api? do
      {:noreply, assign(socket, :confirm_api?, true)}
    else
      {:noreply, refuse(socket)}
    end
  end

  def handle_event("cancel_enable_api", _params, socket),
    do: {:noreply, assign(socket, :confirm_api?, false)}

  def handle_event("confirm_enable_api", _params, %{assigns: %{confirm_api?: true}} = socket) do
    socket = assign(socket, :confirm_api?, false)

    with_api_access(socket, fn socket, scope ->
      case RunnerSetup.enable_machine_api(Scope.user_uuid(scope)) do
        {:ok, _setting} ->
          socket |> reload() |> put_flash(:info, gettext("The machine API is on"))

        {:error, _reason} ->
          put_flash(socket, :error, gettext("The machine API could not be switched on"))
      end
    end)
  end

  def handle_event("confirm_enable_api", _params, socket), do: {:noreply, refuse(socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp advanced?(field), do: field in SmtpSettings.number_fields() or field == "selftest_host"

  defp issue_token(socket, scope) do
    case RunnerKeys.issue(scope) do
      {:ok, %{key: key, token: token, revoked: revoked, left: left}} ->
        new_token = %{
          token: token,
          key_name: key.name,
          command: RunnerSetup.command(socket.assigns.site_url, token),
          revoked: revoked,
          left: left
        }

        socket |> assign(:new_token, new_token) |> reload()

      {:error, reason} ->
        put_flash(socket, :error, issue_error(reason))
    end
  end

  defp issue_error(:forbidden), do: gettext("You need the API permission to issue a token.")

  defp issue_error(:invalid_scopes),
    do:
      gettext(
        "Your account cannot hold the runner token: it needs the \"emails\" permission, and the runner tools must not be hidden in Settings → API."
      )

  defp issue_error(:unavailable),
    do: gettext("The runner needs the machine API of PhoenixKit 2.63 or newer.")

  defp issue_error(_other), do: gettext("The token could not be issued")

  defp mode_message("off", 0), do: gettext("Mailbox verification by SMTP is off")

  defp mode_message("off", drained),
    do:
      gettext(
        "Mailbox verification by SMTP is off; %{n} addresses that were waiting for it were settled without it",
        n: drained
      )

  defp mode_message("local", _drained),
    do: gettext("Mailbox verification will run from this server")

  defp mode_message("runner", _drained),
    do: gettext("Mailbox verification will run through the runner")

  defp revoked_message(revoked, 0) when revoked > 0, do: gettext("Token revoked")

  defp revoked_message(0, _left),
    do:
      gettext(
        "The token belongs to another admin and was not revoked. Revoke it in Settings → API."
      )

  defp revoked_message(_revoked, left),
    do: gettext("Token revoked; %{left} more belong to other admins and still work", left: left)

  defp refuse(socket), do: put_flash(socket, :error, gettext("That action is not available."))

  # The person's rights are read again for this event (core's own rule for pages that
  # change keys and settings); without a known person, or without `api`, nothing happens.
  defp with_api_access(socket, fun) do
    scope = socket.assigns.phoenix_kit_current_scope

    with true <- Config.machine_api_available?(),
         %Scope{} <- scope,
         {:ok, fresh} <- PhoenixKit.API.Access.fresh_scope(scope) do
      {:noreply, fun.(socket, fresh)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end
end
