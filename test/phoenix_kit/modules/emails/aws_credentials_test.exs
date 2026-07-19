defmodule PhoenixKit.Modules.Emails.AwsCredentialsTest do
  @moduledoc """
  AWS SES credential resolution — Integrations connection first, legacy
  `Settings.get_setting("aws_*")` values as fallback (Stage B, B2/B4).
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  defp seed_aws_ses_integration(attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "test")
    {:ok, _} = Integrations.save_setup(uuid, attrs)
    uuid
  end

  describe "get_aws_access_key/0" do
    test "prefers the selected Integrations connection" do
      uuid =
        seed_aws_ses_integration(%{
          "access_key" => "AKIA_NEW",
          "secret_key" => "S",
          "aws_region" => "eu-central-1"
        })

      Settings.update_setting("emails_aws_integration_uuid", uuid)

      assert Emails.get_aws_access_key() == "AKIA_NEW"
    end

    test "falls back to the legacy setting when no integration is selected" do
      Settings.update_setting("aws_access_key_id", "AKIA_LEGACY")

      assert Emails.get_aws_access_key() == "AKIA_LEGACY"
    end
  end

  describe "get_aws_secret_key/0" do
    test "prefers the selected Integrations connection" do
      uuid =
        seed_aws_ses_integration(%{
          "access_key" => "AKIA",
          "secret_key" => "SECRET_NEW",
          "aws_region" => "eu-central-1"
        })

      Settings.update_setting("emails_aws_integration_uuid", uuid)

      assert Emails.get_aws_secret_key() == "SECRET_NEW"
    end

    test "falls back to the legacy setting when no integration is selected" do
      Settings.update_setting("aws_secret_access_key", "SECRET_LEGACY")

      assert Emails.get_aws_secret_key() == "SECRET_LEGACY"
    end
  end

  describe "get_aws_region/0" do
    test "prefers the selected Integrations connection" do
      uuid =
        seed_aws_ses_integration(%{
          "access_key" => "AKIA",
          "secret_key" => "S",
          "aws_region" => "eu-west-1"
        })

      Settings.update_setting("emails_aws_integration_uuid", uuid)

      assert Emails.get_aws_region() == "eu-west-1"
    end

    test "falls back to the legacy setting when no integration is selected" do
      Settings.update_setting("aws_region", "ap-southeast-1")

      assert Emails.get_aws_region() == "ap-southeast-1"
    end
  end
end
