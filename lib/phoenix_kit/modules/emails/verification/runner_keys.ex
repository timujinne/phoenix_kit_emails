defmodule PhoenixKit.Modules.Emails.Verification.RunnerKeys do
  @moduledoc """
  The key an SMTP runner signs in with, issued and revoked through core's own key store
  (`PhoenixKit.API.Keys`, core 2.63.0 and later): nothing here is a second way into the
  site.

  A runner key belongs to the admin who issued it (their rights are checked again on
  every request, so the runner stops when they lose the `emails` permission) and has
  exactly one scope, `Verification.Runners.scope/0`. There is one runner per site:
  `issue/2` revokes the keys that were there before, as far as the admin may manage them
  (an Owner manages every key, any other admin the ones they issued). The rest is
  counted in `:left`, so the section can say that an old key of someone else still works.

  A runner key is a key whose only scope is the runner scope; a key that carries more
  was made for something else and is never touched.
  """

  import Ecto.Query

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @scope Runners.scope()

  @type result :: %{
          optional(:key) => Key.t(),
          optional(:token) => String.t(),
          revoked: non_neg_integer(),
          left: non_neg_integer()
        }

  @type reason ::
          :forbidden
          | :unavailable
          | :owner_inactive
          | :owner_not_allowed
          | :invalid_scopes
          | Ecto.Changeset.t()

  @doc """
  Issues a runner key for the admin behind `scope` and revokes the previous ones.

  `{:ok, %{key:, token:, revoked:, left:}}`: `token` is shown once and exists nowhere
  else, `revoked` is how many earlier runner keys were revoked, `left` how many are still
  alive because the admin may not manage them. When issuing fails nothing is revoked:
  `:forbidden` (no signed-in admin, or no `api` permission), `:invalid_scopes` (the admin
  cannot hold the runner scope: no `emails` permission, or the tools are hidden),
  `:unavailable` (core without the machine API) or core's own reason.
  """
  @spec issue(Scope.t() | nil, DateTime.t()) :: {:ok, result()} | {:error, reason()}
  def issue(scope, now \\ UtilsDate.utc_now())

  def issue(%Scope{user: %User{} = owner} = scope, %DateTime{} = now) do
    if Config.machine_api_available?() do
      previous = manageable(scope)

      with {:ok, key, token} <- Keys.create_key(owner, scope, attrs(now)) do
        revoked = revoke_all(previous, owner)
        {:ok, %{key: key, token: token, revoked: revoked, left: left(key)}}
      end
    else
      {:error, :unavailable}
    end
  end

  def issue(_scope, _now), do: {:error, :forbidden}

  @doc """
  Revokes the runner keys the admin behind `scope` may manage. `{:ok, %{revoked:,
  left:}}`; `left` is how many live runner keys remain (those of other admins).
  """
  @spec revoke(Scope.t() | nil) :: {:ok, result()} | {:error, :forbidden | :unavailable}
  def revoke(%Scope{user: %User{} = user} = scope) do
    if Config.machine_api_available?() do
      revoked = scope |> manageable() |> revoke_all(user)
      {:ok, %{revoked: revoked, left: left(nil)}}
    else
      {:error, :unavailable}
    end
  end

  def revoke(_scope), do: {:error, :forbidden}

  @doc "The live runner keys of the whole site, newest first."
  @spec active() :: [Key.t()]
  def active do
    from(k in Key,
      where: ^@scope in k.scopes,
      order_by: [desc: k.inserted_at, desc: k.uuid]
    )
    |> repo().all()
    |> Enum.filter(&(&1.scopes == [@scope] and Keys.dead_reason(&1) == nil))
  end

  defp attrs(now), do: %{name: "SMTP runner (#{DateTime.to_date(now)})", scopes: [@scope]}

  defp manageable(scope), do: Enum.filter(active(), &Keys.can_manage?(scope, &1))

  defp revoke_all(keys, user) do
    Enum.count(keys, fn key -> match?({:ok, _}, Keys.revoke(key, user.uuid)) end)
  end

  defp left(new_key) do
    Enum.count(active(), fn key -> is_nil(new_key) or key.uuid != new_key.uuid end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
