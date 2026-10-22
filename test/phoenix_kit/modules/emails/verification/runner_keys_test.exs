defmodule PhoenixKit.Modules.Emails.Verification.RunnerKeysTest do
  @moduledoc """
  Issuing and revoking the key of the SMTP runner through core's own key store: the key
  has exactly the runner scope, a new one replaces the old one (one runner per site),
  the token exists only in the answer, and what an admin may not manage is left alone.
  """

  # Not async: the API processes and the module registry are named.
  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import PhoenixKitEmails.Test.ApiHarness

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Modules.Emails.Verification.RunnerKeys
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitEmails.Test.Repo

  @now ~U[2026-10-20 10:00:00Z]

  setup do
    owner = setup_api()
    true = owner |> scope_of() |> Scope.owner?()
    {admin, _role} = user_with(["emails"])
    %{admin: admin, scope: scope_of(admin), owner_scope: scope_of(owner)}
  end

  defp keys, do: Repo.all(from(k in Key, order_by: [asc: k.inserted_at, asc: k.uuid]))

  defp live?(%Key{} = key), do: Keys.dead_reason(key) == nil

  describe "issue/2" do
    test "creates a key with exactly the runner scope, named by the date", %{
      admin: admin,
      scope: scope
    } do
      assert {:ok, %{key: key, token: token, revoked: 0, left: 0}} =
               RunnerKeys.issue(scope, @now)

      assert key.scopes == ["emails.smtp_runner:run"]
      assert key.name == "SMTP runner (2026-10-20)"
      assert key.user_uuid == admin.uuid
      assert key.created_by_uuid == admin.uuid
      assert key.requires_approval == false
      assert key.allowed_ips == []
      assert key.expires_at == nil
      assert token =~ ~r/\Apk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}\z/

      assert [stored] = keys()
      assert stored.uuid == key.uuid
    end

    test "the token is the only place the secret exists", %{scope: scope} do
      {:ok, %{token: token, key: key}} = RunnerKeys.issue(scope, @now)

      [_pk, _prefix, secret] = String.split(token, "_", parts: 3)
      refute inspect(Repo.get!(Key, key.uuid)) =~ secret
    end

    test "the token works against the runner tools", %{scope: scope} do
      {:ok, %{token: token}} = RunnerKeys.issue(scope, @now)

      conn = request(token, "emails.claim_smtp_jobs", %{"max_sessions" => 0})
      assert conn.status == 200
    end

    test "a new key revokes the previous runner key: one runner per site", %{scope: scope} do
      {:ok, %{key: first, token: first_token}} = RunnerKeys.issue(scope, @now)

      assert {:ok, %{key: second, revoked: 1, left: 0}} = RunnerKeys.issue(scope, @now)

      refute Repo.get!(Key, first.uuid) |> live?()
      assert Repo.get!(Key, second.uuid) |> live?()

      assert request(first_token, "emails.claim_smtp_jobs", %{"max_sessions" => 0}).status == 401
    end

    test "a key made by hand with only the runner scope counts as the runner key", %{
      admin: admin,
      scope: scope
    } do
      {hand_made, _token} = issue_key(admin, ["emails.smtp_runner:run"], %{name: "Hand made"})
      {:ok, %{key: second, revoked: 1}} = RunnerKeys.issue(scope, @now)

      refute Repo.get!(Key, hand_made.uuid) |> live?()
      assert Repo.get!(Key, second.uuid) |> live?()
    end

    test "a key that carries more than the runner scope is not a runner key", %{
      admin: admin,
      scope: scope
    } do
      shared =
        Repo.insert!(%Key{
          name: "Shared",
          prefix: "abcd1234",
          secret_hash: :crypto.hash(:sha256, "x"),
          scopes: ["emails.smtp_runner:run", "other.thing:read"],
          user_uuid: admin.uuid,
          created_by_uuid: admin.uuid
        })

      {:ok, %{revoked: 0}} = RunnerKeys.issue(scope, @now)
      assert Repo.get!(Key, shared.uuid) |> live?()
    end

    test "a key issued by another admin is left alive and counted", %{scope: scope} do
      {other_admin, _} = user_with(["emails"])
      {:ok, %{key: theirs}} = RunnerKeys.issue(scope_of(other_admin), @now)

      assert {:ok, %{key: mine, revoked: 0, left: 1}} = RunnerKeys.issue(scope, @now)

      assert Repo.get!(Key, theirs.uuid) |> live?()
      assert Repo.get!(Key, mine.uuid) |> live?()
    end

    test "an Owner replaces the key of any admin", %{scope: scope, owner_scope: owner_scope} do
      {:ok, %{key: theirs}} = RunnerKeys.issue(scope, @now)

      assert {:ok, %{revoked: 1, left: 0}} = RunnerKeys.issue(owner_scope, @now)
      refute Repo.get!(Key, theirs.uuid) |> live?()
    end

    test "without the api permission nothing is created" do
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

      assert {:error, :forbidden} = RunnerKeys.issue(scope_of(user), @now)
      assert keys() == []
    end

    test "an admin without the emails permission cannot hold the scope" do
      {user, _role} = user_with([])

      assert {:error, :invalid_scopes} = RunnerKeys.issue(scope_of(user), @now)
      assert keys() == []
    end

    test "a failed issue keeps the previous key", %{scope: scope} do
      {:ok, %{key: first}} = RunnerKeys.issue(scope, @now)
      put_setting("api_disabled_tools", "emails.claim_smtp_jobs\nemails.report_smtp_results")

      assert {:error, :invalid_scopes} = RunnerKeys.issue(scope, @now)
      assert Repo.get!(Key, first.uuid) |> live?()
    end

    test "on a core without the machine API there is nothing to issue", %{scope: scope} do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      assert {:error, :unavailable} = RunnerKeys.issue(scope, @now)
      assert keys() == []
    end

    test "no signed-in user is refused" do
      assert {:error, :forbidden} = RunnerKeys.issue(nil, @now)
      assert {:error, :forbidden} = RunnerKeys.revoke(nil)
    end
  end

  describe "revoke/1" do
    test "revokes the runner key at once", %{scope: scope} do
      {:ok, %{key: key, token: token}} = RunnerKeys.issue(scope, @now)

      assert {:ok, %{revoked: 1, left: 0}} = RunnerKeys.revoke(scope)

      refute Repo.get!(Key, key.uuid) |> live?()
      assert request(token, "emails.claim_smtp_jobs", %{"max_sessions" => 0}).status == 401
    end

    test "with no key it revokes nothing", %{scope: scope} do
      assert {:ok, %{revoked: 0, left: 0}} = RunnerKeys.revoke(scope)
    end

    test "a key of another admin stays, and the count says so", %{scope: scope} do
      {other_admin, _} = user_with(["emails"])
      {:ok, %{key: theirs}} = RunnerKeys.issue(scope_of(other_admin), @now)

      assert {:ok, %{revoked: 0, left: 1}} = RunnerKeys.revoke(scope)
      assert Repo.get!(Key, theirs.uuid) |> live?()
    end
  end

  describe "active/0" do
    test "lists the live runner keys of the whole site, newest first", %{
      scope: scope,
      owner_scope: owner_scope
    } do
      assert RunnerKeys.active() == []

      {other_admin, _} = user_with(["emails"])
      {:ok, %{key: a}} = RunnerKeys.issue(scope_of(other_admin), @now)
      {:ok, %{key: b}} = RunnerKeys.issue(scope, @now)

      # `a` is older: the order comes from the time the keys were made.
      older = DateTime.add(DateTime.utc_now(), -3600)
      Repo.update_all(from(k in Key, where: k.uuid == ^a.uuid), set: [inserted_at: older])

      assert RunnerKeys.active() |> Enum.map(& &1.uuid) == [b.uuid, a.uuid]

      RunnerKeys.revoke(owner_scope)
      assert RunnerKeys.active() == []
    end
  end
end
