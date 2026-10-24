defmodule PhoenixKitEmails.Test.ApiHarness do
  @moduledoc """
  Sets the machine API of core up for a test of the runner tools: the processes the
  API needs, the module registry with the Emails module in it, the admin switch, and
  real users and keys made through `PhoenixKit.API.Keys.create_key/3`. Needs a test
  case with the database sandbox and `async: false` (everything it starts is named).
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import Plug.Conn
  import Plug.Test, only: [conn: 2]

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.REST
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitEmails.Test.Repo

  @scope "emails.smtp_runner:run"

  @doc "The scope of the runner tools."
  def scope, do: @scope

  @doc """
  Starts what the API needs and switches the admin API on. The Emails module is
  registered (and enabled) for the length of the test. Returns the Owner (the first
  user registered, who holds every permission).
  """
  def setup_api do
    # Own the PubSub supervisor directly: core's Manager links it indirectly and
    # can exit before its named supervisor finishes, racing the next test.
    start_supervised!({Phoenix.PubSub, name: :phoenix_kit_internal_pubsub})
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    start_supervised!(%{
      id: :rate_limit_backend,
      start: {PhoenixKit.Users.RateLimiter.Backend, :start_link, [[]]}
    })

    start_supervised!(ModuleRegistry)

    :ok = ModuleRegistry.register(PhoenixKit.Modules.Emails)
    on_exit(fn -> :persistent_term.erase({PhoenixKit, :registered_modules}) end)

    put_setting("email_enabled", "true")
    put_setting("api_admin_enabled", "true")

    # The first user ever registered becomes the Owner, who holds every permission;
    # the users the tests make must be ordinary ones.
    register_user()
  end

  def put_setting(key, value) do
    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, _} = Settings.update_setting(key, value)
    end)

    :ok
  end

  @doc "A confirmed user whose only role grants `permissions` (and `api`, so the user can own a key)."
  def user_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "RunnerApi#{System.unique_integer([:positive])}"})

    for key <- Enum.uniq(["api" | permissions]),
        do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    user = register_user()
    {:ok, _} = Roles.assign_role(user, role.name)
    {user, role}
  end

  defp register_user do
    {:ok, user} =
      Auth.register_user(
        %{
          email: "runner_owner_#{System.unique_integer([:positive])}@acme-mail.test",
          password: "ValidPassword123!"
        },
        nil
      )

    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()
  end

  def scope_of(user), do: Scope.for_user(user, narrow: false)

  @doc "A key of `owner` with the runner scope (or `scopes`), made by the owner. `{key, token}`."
  def issue_key(owner, scopes \\ [@scope], attrs \\ %{}) do
    attrs = Map.merge(%{name: "SMTP runner", scopes: scopes}, attrs)
    {:ok, key, token} = Keys.create_key(owner, scope_of(owner), attrs)
    {key, token}
  end

  @doc "An API request, from a fresh client address (the rate-limit buckets are per address)."
  def request(token, tool, body, opts \\ []) do
    ip = Keyword.get_lazy(opts, :ip, &unique_ip/0)

    :post
    |> conn("/" <> tool)
    |> Map.put(:remote_ip, ip |> String.to_charlist() |> :inet.parse_address() |> elem(1))
    |> Map.put(:body_params, body)
    |> Map.put(:params, body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> REST.call(REST.init(audience: :admin))
  end

  @doc "`GET /`: the tools the key may call."
  def list_tools(token) do
    :get
    |> conn("/")
    |> Map.put(
      :remote_ip,
      unique_ip() |> String.to_charlist() |> :inet.parse_address() |> elem(1)
    )
    |> put_req_header("authorization", "Bearer " <> token)
    |> REST.call(REST.init(audience: :admin))
  end

  def json(%Plug.Conn{resp_body: body}), do: JSON.decode!(body)

  def unique_ip do
    n = System.unique_integer([:positive])
    "10.#{rem(div(n, 65_536), 250) + 1}.#{rem(div(n, 256), 250) + 1}.#{rem(n, 250) + 1}"
  end
end
