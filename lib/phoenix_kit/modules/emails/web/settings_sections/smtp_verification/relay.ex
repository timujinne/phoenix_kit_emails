defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.SmtpVerification.Relay do
  @moduledoc """
  A small process that lives as long as the LiveView showing the "Mailbox verification
  (SMTP)" section and talks to the section for it.

  A section is a `LiveComponent`: it has no `handle_info/2` of its own, and the page
  that hosts it (core's Email Sending page) does not forward messages to it. So this
  process does what the section cannot:

    * it subscribes to the runner topic (`Verification.subscribe_runner/0`) and turns
      every announcement into `send_update(view, component, id: id, relay_event: :runner)`;
    * every `@tick_ms` it sends `relay_event: :tick`, which moves the "N s ago" text on
      without a database read (the section reads the status again only on an
      announcement and about once a minute);
    * once, at the start, when asked to, it reads the page's signed-in admin out of the
      page's state (`scope_of/1`) and hands it to the section as
      `relay_event: {:scope, scope}`.

  It monitors the view and stops when the view goes away.
  """

  use GenServer

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Users.Auth.Scope

  @tick_ms 5_000
  @scope_attempts 3
  @scope_timeout_ms 2_000
  @scope_backoff_ms 250

  @doc """
  Starts a relay for the LiveView `view` and the component `{component, id}`. With
  `fetch_scope?` the relay also looks up the page's admin once. Not linked: it ends with
  the view.
  """
  @spec start(pid(), module(), String.t(), boolean(), pos_integer()) :: GenServer.on_start()
  def start(view, component, id, fetch_scope?, tick_ms \\ @tick_ms) when is_pid(view) do
    GenServer.start(__MODULE__, {view, component, id, fetch_scope?, tick_ms})
  end

  @doc "Reads the page's scope once, without subscribing to runner updates or ticking."
  @spec fetch_scope(pid(), module(), String.t()) :: GenServer.on_start()
  def fetch_scope(view, component, id) do
    GenServer.start(__MODULE__, {:scope, view, component, id})
  end

  @doc "Stops a relay started with `start/5`; nothing happens when it is gone already."
  @spec stop(pid()) :: :ok
  def stop(relay) when is_pid(relay) do
    GenServer.stop(relay, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  The signed-in admin's scope (`:phoenix_kit_current_scope`) of the LiveView `view`, or
  `nil` when it cannot be read.

  Core renders a settings section with nothing but its `id`, so the section never
  learns who is looking at it. The page process holds the scope in its socket; this
  asks for the state from another process (a process cannot ask itself). The state is
  that of a `Phoenix.LiveView.Channel`: a map with a `:socket`. Anything else, or no
  answer in two seconds, is `nil`, and the section then does not offer what needs a
  person's rights. A page that is busy when asked (no answer in time) is asked again,
  a few times, with a short pause (`:attempts`, `:timeout`, `:backoff_ms`).

  This lookup is a stopgap: it goes away when core passes `phoenix_kit_current_scope` to
  the settings sections itself. It depends on the shape of LiveView's process state;
  `smtp_verification_live_test.exs` reads the scope out of a real LiveView and is what
  fails when that shape changes.
  """
  @spec scope_of(pid(), keyword()) :: Scope.t() | nil
  def scope_of(view, opts \\ []) when is_pid(view) do
    attempts = Keyword.get(opts, :attempts, @scope_attempts)
    timeout = Keyword.get(opts, :timeout, @scope_timeout_ms)
    backoff = Keyword.get(opts, :backoff_ms, @scope_backoff_ms)
    ask(view, attempts, timeout, backoff)
  end

  defp ask(view, attempts, timeout, backoff) do
    case :sys.get_state(view, timeout) do
      %{socket: %{assigns: %{phoenix_kit_current_scope: %Scope{} = scope}}} -> scope
      _ -> nil
    end
  catch
    :exit, {:timeout, _} when attempts > 1 ->
      Process.sleep(backoff)
      ask(view, attempts - 1, timeout, backoff)

    :exit, _ ->
      nil
  end

  @impl true
  def init({:scope, view, component, id}) do
    Process.monitor(view)
    send(self(), :scope)
    {:ok, %{view: view, component: component, id: id, scope_only?: true}}
  end

  def init({view, component, id, fetch_scope?, tick_ms}) do
    Process.monitor(view)
    _ = Verification.subscribe_runner()
    if fetch_scope?, do: send(self(), :scope)
    Process.send_after(self(), :tick, tick_ms)

    {:ok, %{view: view, component: component, id: id, tick_ms: tick_ms, scope_only?: false}}
  end

  @impl true
  def handle_info(:scope, state) do
    notify(state, {:scope, scope_of(state.view)})
    if state.scope_only?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:email_verify_runner, _event}, state) do
    notify(state, :runner)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    notify(state, :tick)
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, view, _reason}, %{view: view} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp notify(%{view: view, component: component, id: id}, event) do
    Phoenix.LiveView.send_update(view, component, id: id, relay_event: event)
  end
end
