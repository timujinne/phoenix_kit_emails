defmodule PhoenixKit.Modules.Emails.MigrateLegacyTest do
  @moduledoc """
  `Emails.migrate_legacy/0` moves plaintext legacy AWS SES settings into
  an encrypted `aws_ses` Integrations connection (Stage B, B4).
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  describe "migrate_legacy/0" do
    test "moves legacy AWS SES settings into an encrypted Integrations connection" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")
      Settings.update_setting("aws_region", "eu-west-1")

      assert :ok = Emails.migrate_legacy()

      uuid = Settings.get_setting("emails_aws_integration_uuid")
      assert is_binary(uuid) and uuid != ""

      raw = Settings.get_json_setting_by_uuid(uuid)
      assert String.starts_with?(raw["secret_key"], "enc:v1:")

      assert {:ok, creds} = Integrations.get_credentials(uuid)
      assert creds["access_key"] == "AKIA_LEGACY"
      assert creds["secret_key"] == "SECRET_LEGACY"
      assert creds["aws_region"] == "eu-west-1"
    end

    test "defaults the region to us-east-1 when no legacy region is set" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      :ok = Emails.migrate_legacy()

      uuid = Settings.get_setting("emails_aws_integration_uuid")
      assert {:ok, %{"aws_region" => "us-east-1"}} = Integrations.get_credentials(uuid)
    end

    test "is idempotent — re-running does not create a second connection" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      :ok = Emails.migrate_legacy()
      uuid = Settings.get_setting("emails_aws_integration_uuid")

      :ok = Emails.migrate_legacy()

      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
      assert length(Integrations.list_connections("aws_ses")) == 1
    end

    test "no-ops when there are no legacy credentials" do
      assert :ok = Emails.migrate_legacy()
      assert Settings.get_setting("emails_aws_integration_uuid") in [nil, ""]
      assert Integrations.list_connections("aws_ses") == []
    end

    test "does not create a live SES request during boot migration" do
      # Regression for the MAJOR finding: migrate_legacy/0 used to call
      # Integrations.validate_connection/1 (a real GetSendQuota HTTPS
      # request) as its last step. There's no Swoosh-style test seam for
      # that call, so the strongest assertion available here is behavioral:
      # this whole test file completes near-instantly against completely
      # fake credentials that would fail SES auth if any network call were
      # actually attempted — a live probe would either time out (up to the
      # validator's 15s deadline) or resolve quickly with an auth failure,
      # neither of which is compatible with this file's runtime.
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      {elapsed_us, :ok} = :timer.tc(fn -> Emails.migrate_legacy() end)

      assert elapsed_us < 1_000_000

      uuid = Settings.get_setting("emails_aws_integration_uuid")
      connection = Enum.find(Integrations.list_connections("aws_ses"), &(&1.uuid == uuid))

      # No live probe ran, so the connection lands at whatever save_setup/3
      # computes from credential presence alone ("configured"), never
      # "connected" — that status now only comes from an explicit Test
      # Connection click.
      assert connection.data["status"] == "configured"
    end

    test "retrying after a simulated mid-flight crash (connection created, guard not yet written) reuses the same connection instead of creating a second one" do
      # Simulates a crash between add_connection/2 succeeding and
      # emails_aws_integration_uuid being persisted — the exact window that
      # used to create a second "Amazon SES (migrated)" connection on every
      # retry. Reproduced directly (not by injecting a real crash) since
      # that's the observable state such a crash would leave behind: a
      # connection exists under the migrated name, but the guard setting is
      # still blank and no credentials were saved yet.
      {:ok, %{uuid: pre_existing_uuid}} =
        Integrations.add_connection("aws_ses", "Amazon SES (migrated)")

      assert Settings.get_setting("emails_aws_integration_uuid") in [nil, ""]

      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      assert :ok = Emails.migrate_legacy()

      assert Settings.get_setting("emails_aws_integration_uuid") == pre_existing_uuid
      assert length(Integrations.list_connections("aws_ses")) == 1

      assert {:ok, creds} = Integrations.get_credentials(pre_existing_uuid)
      assert creds["access_key"] == "AKIA_LEGACY"
      assert creds["secret_key"] == "SECRET_LEGACY"
    end
  end
end
