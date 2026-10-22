defmodule PhoenixKit.Modules.Emails.Verification.RunnersTest do
  @moduledoc """
  The runner side the UI reads: the heartbeat row, the status (online, never
  connected, port 25, paused, MAIL FROM missing), whose key the runner works with and
  the warnings when that key can no longer work, the self-test host, the PubSub
  announcements and clearing a pause.
  """

  # Not async: the API processes, the module registry and the PubSub manager are named.
  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import PhoenixKitEmails.Test.ApiHarness

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key, as: ApiKey
  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @now ~U[2026-10-20 10:00:00Z]

  setup do
    setup_api()
    put_setting("email_verify_smtp_mode", "runner")
    put_setting("from_email", "mail@acme-mail.test")
    FakeResolver.put("acme-mail.test", mx: {:ok, [%{host: "mx.acme-mail.test", pref: 10}]})

    {owner, role} = user_with(["emails"])
    {key, token} = issue_key(owner)
    actor = %{key_uuid: key.uuid, ip: "203.0.113.7"}
    %{owner: owner, role: role, key: key, token: token, actor: actor}
  end

  describe "runner_protocol_version/0" do
    test "is a dotted version of its own, not the version of the package" do
      assert Runners.runner_protocol_version() =~ ~r/\A\d+\.\d+\.\d+\z/

      refute Runners.runner_protocol_version() ==
               to_string(Application.spec(:phoenix_kit_emails, :vsn))
    end
  end

  describe "online?/3" do
    test "a runner is online within three idle polls of its last contact" do
      assert Runners.online?(@now, DateTime.add(@now, 89), 30)
      refute Runners.online?(@now, DateTime.add(@now, 90), 30)
      refute Runners.online?(nil, @now, 30)
    end

    test "the idle poll defaults to the setting" do
      put_setting("email_verify_smtp_idle_poll_s", "10")

      assert Runners.online?(@now, DateTime.add(@now, 29))
      refute Runners.online?(@now, DateTime.add(@now, 30))
    end
  end

  describe "heartbeat/3" do
    test "creates the row on first contact and updates it after", %{actor: actor, key: key} do
      info = %{
        name: "WORKSTATION",
        version: "1.0.0",
        os: "Windows",
        helo_auto: "h.example.ee",
        port25: "open"
      }

      runner = Runners.heartbeat(actor, info, @now)

      assert runner.api_key_uuid == key.uuid

      assert {runner.name, runner.version, runner.os, runner.helo_auto} ==
               {"WORKSTATION", "1.0.0", "Windows", "h.example.ee"}

      assert {runner.public_ip, runner.port25, runner.last_seen_at} ==
               {"203.0.113.7", "open", @now}

      assert runner.port25_checked_at == @now
      assert runner.jobs_done == 0

      later = DateTime.add(@now, 30)
      again = Runners.heartbeat(%{actor | ip: "203.0.113.8"}, %{version: "1.0.1"}, later)

      assert again.uuid == runner.uuid

      assert {again.name, again.version, again.public_ip, again.last_seen_at} ==
               {"WORKSTATION", "1.0.1", "203.0.113.8", later}

      assert again.port25_checked_at == @now
      assert Repo.aggregate(Runner, :count) == 1
    end

    test "helo_auto sent as nil clears the stored name; left out it keeps it", %{actor: actor} do
      Runners.heartbeat(actor, %{helo_auto: "localhost"}, @now)

      assert Runners.heartbeat(actor, %{name: "BOX"}, DateTime.add(@now, 1)).helo_auto ==
               "localhost"

      assert Runners.heartbeat(actor, %{helo_auto: nil}, DateTime.add(@now, 2)).helo_auto == nil
      assert Runners.heartbeat(actor, %{helo_auto: nil}, DateTime.add(@now, 3)).name == "BOX"
    end

    test "a port25 value it does not know is dropped, blank texts are not stored", %{actor: actor} do
      runner = Runners.heartbeat(actor, %{port25: "maybe", name: "   "}, @now)
      assert runner.port25 == "unknown"
      assert runner.name == nil
      assert runner.port25_checked_at == nil
    end

    test "long values are cut to their columns", %{actor: actor} do
      runner =
        Runners.heartbeat(
          actor,
          %{name: String.duplicate("n", 400), version: String.duplicate("9", 90)},
          @now
        )

      assert String.length(runner.name) == 255
      assert String.length(runner.version) == 32
    end

    test "one row per key", %{owner: owner, actor: actor} do
      {other_key, _} = issue_key(owner)
      Runners.heartbeat(actor, %{}, @now)
      Runners.heartbeat(%{actor | key_uuid: other_key.uuid}, %{}, @now)
      Runners.heartbeat(actor, %{}, @now)

      assert Repo.aggregate(Runner, :count) == 2
    end
  end

  describe "announcements on email_verify:runner" do
    test "a heartbeat is announced at most every five seconds", %{actor: actor} do
      assert Runners.topic() == "email_verify:runner"
      :ok = Verification.subscribe_runner()

      first = Runners.heartbeat(actor, %{port25: "open"}, @now)
      assert_receive {:email_verify_runner, %{event: :heartbeat, runner_uuid: uuid}}
      assert uuid == first.uuid

      Runners.heartbeat(actor, %{port25: "open"}, DateTime.add(@now, 2))
      refute_receive {:email_verify_runner, _}, 50

      Runners.heartbeat(actor, %{port25: "open"}, DateTime.add(@now, 6))
      assert_receive {:email_verify_runner, %{event: :heartbeat}}
    end

    test "settling a session does not postpone the next announcement", %{actor: actor} do
      runner = Runners.heartbeat(actor, %{}, @now)
      :ok = Verification.subscribe_runner()

      Runners.record_session(
        runner,
        "d.example.ee",
        %{failed: false},
        "answered",
        1,
        DateTime.add(@now, 3)
      )

      Runners.heartbeat(actor, %{}, DateTime.add(@now, 6))

      assert_receive {:email_verify_runner, %{event: :heartbeat}}
    end

    test "settling a session of a runner whose row is gone does not raise, and says so" do
      gone = %Runner{uuid: Ecto.UUID.generate()}

      log =
        capture_log(fn ->
          assert Runners.record_session(
                   gone,
                   "d.example.ee",
                   %{failed: true},
                   "connect_failed",
                   1,
                   @now
                 ) == []

          assert Runners.record_session(
                   gone,
                   "d.example.ee",
                   %{failed: false},
                   "answered",
                   1,
                   @now
                 ) == []
        end)

      assert log =~ "whose row is gone"
      assert log =~ gone.uuid
      refute log =~ "d.example.ee"
    end

    test "a changed port-25 finding is announced at once", %{actor: actor} do
      Runners.heartbeat(actor, %{port25: "open"}, @now)
      :ok = Verification.subscribe_runner()

      Runners.heartbeat(actor, %{port25: "blocked"}, DateTime.add(@now, 1))
      assert_receive {:email_verify_runner, %{event: :heartbeat}}
    end

    test "clearing a pause is announced", %{actor: actor} do
      runner = Runners.heartbeat(actor, %{}, @now)

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [paused_until: DateTime.add(@now, 99_999_999), pause_reason: "x"]
      )

      :ok = Verification.subscribe_runner()

      assert {:ok, 1} = Verification.clear_runner_pause()
      assert_receive {:email_verify_runner, %{event: :resumed}}
      assert {:ok, 0} = Verification.clear_runner_pause()
    end
  end

  describe "status/1" do
    test "before any contact" do
      status = Runners.status(@now)

      assert status.state == :never_connected
      assert status.runner == nil
      assert status.paused == nil
      refute status.port25_blocked
      assert status.mode == "runner"
      assert status.api_available
      assert status.queue == %{queued: 0, leased: 0}
    end

    test "online while the last contact is younger than three poll intervals", %{actor: actor} do
      Runners.heartbeat(actor, %{name: "BOX"}, @now)

      assert Runners.status(DateTime.add(@now, 89)).state == :online
      assert Runners.status(DateTime.add(@now, 91)).state == :offline
      assert Runners.status(DateTime.add(@now, 91)).runner.name == "BOX"
    end

    test "the window follows the poll interval setting", %{actor: actor} do
      put_setting("email_verify_smtp_idle_poll_s", "10")
      Runners.heartbeat(actor, %{}, @now)

      assert Runners.status(DateTime.add(@now, 29)).state == :online
      assert Runners.status(DateTime.add(@now, 31)).state == :offline
    end

    test "port 25 blocked", %{actor: actor} do
      Runners.heartbeat(actor, %{port25: "blocked"}, @now)
      assert Runners.status(@now).port25_blocked
    end

    test "paused, with the reason, until the pause ends", %{actor: actor} do
      runner = Runners.heartbeat(actor, %{}, @now)
      until = DateTime.add(@now, 600)

      Repo.update_all(from(r in Runner, where: r.uuid == ^runner.uuid),
        set: [paused_until: until, pause_reason: "port 25 closed"]
      )

      assert Runners.status(@now).paused == %{reason: "port 25 closed", until: until}
      assert Runners.status(DateTime.add(@now, 601)).paused == nil
    end

    test "MAIL FROM: the site's sender, an override, or missing", %{actor: actor} do
      Runners.heartbeat(actor, %{}, @now)

      assert %{
               mail_from: "mail@acme-mail.test",
               mail_from_source: :site_sender,
               mail_from_missing: false
             } = Runners.status(@now)

      put_setting("email_verify_smtp_mail_from", "verify@acme-mail.test")

      assert %{mail_from: "verify@acme-mail.test", mail_from_source: :override} =
               Runners.status(@now)

      put_setting("email_verify_smtp_mail_from", "")
      put_setting("from_email", "noreply@localhost")

      assert %{mail_from: nil, mail_from_source: :none, mail_from_missing: true} =
               Runners.status(@now)
    end

    test "the latest runner is the one shown", %{owner: owner, actor: actor} do
      {old_key, _} = issue_key(owner)
      Runners.heartbeat(%{actor | key_uuid: old_key.uuid}, %{name: "OLD"}, @now)
      Runners.heartbeat(actor, %{name: "NEW"}, DateTime.add(@now, 60))

      assert Runners.status(DateTime.add(@now, 61)).runner.name == "NEW"
    end

    test "Verification.runner_status/0 is the same thing", %{actor: actor} do
      Runners.heartbeat(actor, %{name: "BOX"})
      assert %{state: :online, runner: %{name: "BOX"}} = Verification.runner_status()
    end

    test "on a core without the machine API it says so and does not crash" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      status = Runners.status(@now)
      refute status.api_available
      assert status.mode == "runner"
      assert Verification.smtp_mode() == "off"
    end
  end

  describe "status/1: whose key it is" do
    test "before the first connection: the owner of the live runner key", %{
      owner: owner,
      key: key
    } do
      assert %{runner: nil, owner: owner_info} = Runners.status(@now)
      assert %{key_uuid: key_uuid, user_uuid: user_uuid, email: email, warning: nil} = owner_info
      assert key_uuid == key.uuid
      assert user_uuid == owner.uuid
      assert email == owner.email
    end

    test "before the first connection and the owner is deactivated: the same warning", %{
      owner: owner
    } do
      owner |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert %{runner: nil, owner: %{warning: :owner_inactive}} = Runners.status(@now)
    end

    test "before the first connection and no runner key: no owner", %{owner: owner, key: key} do
      {:ok, _} = Keys.revoke(key, owner.uuid)

      assert %{runner: nil, owner: nil} = Runners.status(@now)
    end

    test "the runner row is revoked and a new token was issued: the new owner is shown", %{
      owner: owner,
      key: key,
      actor: actor
    } do
      Runners.heartbeat(actor, %{}, @now)
      {:ok, _} = Keys.revoke(key, owner.uuid)
      {new_key, _token} = issue_key(owner)

      assert %{owner: %{key_uuid: key_uuid, warning: nil}} = Runners.status(@now)
      assert key_uuid == new_key.uuid
    end

    test "the mode local has no owner" do
      put_setting("email_verify_smtp_mode", "local")

      assert %{owner: nil} = Runners.status(@now)
    end

    test "the owner, as the page shows them", %{owner: owner, key: key, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)
      owner |> Ecto.Changeset.change(first_name: "Mari", last_name: "Tamm") |> Repo.update!()

      assert %{owner: owner_info} = Runners.status(@now)

      assert owner_info == %{
               key_uuid: key.uuid,
               key_name: "SMTP runner",
               user_uuid: owner.uuid,
               email: owner.email,
               name: "Mari Tamm",
               active: true,
               emails_permission: true,
               warning: nil
             }
    end

    test "a deactivated owner: the runner will stop", %{owner: owner, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)
      owner |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert %{owner: %{active: false, emails_permission: false, warning: :owner_inactive}} =
               Runners.status(@now)
    end

    test "an owner without the emails permission", %{role: role, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)
      :ok = Permissions.revoke_permission(role.uuid, "emails")

      assert %{owner: %{active: true, emails_permission: false, warning: :no_emails_permission}} =
               Runners.status(@now)
    end

    test "a revoked key", %{owner: owner, key: key, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)
      {:ok, _} = Keys.revoke(key, owner.uuid)

      assert %{owner: %{warning: :key_revoked}} = Runners.status(@now)
    end

    test "an expired key", %{key: key, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)

      Repo.update_all(from(k in ApiKey, where: k.uuid == ^key.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
      )

      assert %{owner: %{warning: :key_expired}} = Runners.status(@now)
    end

    test "a key that no longer exists leaves the owner unknown", %{key: key, actor: actor} do
      Runners.heartbeat(actor, %{}, @now)
      Repo.delete_all(from(k in ApiKey, where: k.uuid == ^key.uuid))

      assert %{owner: nil} = Runners.status(@now)
    end
  end

  describe "selftest_host/0" do
    test "the setting wins" do
      put_setting("email_verify_smtp_selftest_host", "mx9.acme-mail.test")
      assert Runners.selftest_host() == "mx9.acme-mail.test"
    end

    test "otherwise the first mail host of the MAIL FROM domain" do
      assert Runners.selftest_host() == "mx.acme-mail.test"

      put_setting("email_verify_smtp_mail_from", "verify@other.ee")

      FakeResolver.put("other.ee",
        mx: {:ok, [%{host: "a.mx.other.ee", pref: 5}, %{host: "b.mx.other.ee", pref: 10}]}
      )

      assert Runners.selftest_host() == "a.mx.other.ee"
    end

    test "else the site's own host; never someone else's" do
      put_setting("from_email", "noreply@localhost")
      host = URI.parse(Routes.base_url()).host
      FakeResolver.put(host, mx: {:ok, [%{host: "mail." <> host, pref: 10}]})

      assert Runners.selftest_host() == "mail." <> host
    end

    test "nil when nothing can be found" do
      put_setting("from_email", "noreply@localhost")
      assert Runners.selftest_host() == nil
    end
  end
end
