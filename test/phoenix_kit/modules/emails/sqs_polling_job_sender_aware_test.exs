defmodule PhoenixKit.Modules.Emails.SQSPollingJobSenderAwareTest do
  @moduledoc """
  Sender-aware gate on `SQSPollingJob.should_poll?/0`, mirroring
  `BrevoPollingJob`'s: SQS credentials being *reachable* isn't the same
  as SES actually being the thing sending mail right now. Only tests the
  gate itself (`should_poll?/0` — public, `@doc false`, specifically so
  this doesn't need a real SQS/network round trip) — the receive/process
  cycle this gate wraps is unchanged and untested here.
  """

  # aws_configured?/0 reads through `Emails.aws_ses_credentials/0`'s TTL
  # cache (60s, keyed process-globally via `PhoenixKit.Cache`, not scoped
  # to a test's DB transaction) — under async: true a concurrent test's
  # freshly-created (and later rolled-back) integration can still leak
  # into this test's cached read. async: false + explicit invalidation
  # keeps each test's gate check honest.
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Settings

  setup do
    # Defensive against a CI environment that happens to export real AWS
    # credentials: without this, "no legacy AWS credentials" below could
    # false-pass (should_poll?/0 reading real creds through env-config,
    # rather than genuinely proving the "nothing configured" case).
    prior_access_key = System.get_env("AWS_ACCESS_KEY_ID")
    prior_secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    System.delete_env("AWS_ACCESS_KEY_ID")
    System.delete_env("AWS_SECRET_ACCESS_KEY")

    on_exit(fn ->
      if prior_access_key, do: System.put_env("AWS_ACCESS_KEY_ID", prior_access_key)
      if prior_secret_key, do: System.put_env("AWS_SECRET_ACCESS_KEY", prior_secret_key)
    end)

    Emails.invalidate_aws_credentials_cache()
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_ses_events(true)
    {:ok, _} = Emails.set_sqs_polling(true)
    on_exit(fn -> Emails.invalidate_aws_credentials_cache() end)
    :ok
  end

  defp create_ses_profile(opts \\ []) do
    enabled = Keyword.get(opts, :enabled, true)

    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "secret"
      })

    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: enabled
      })

    profile
  end

  test "no SendProfile and no legacy AWS credentials: should_poll?/0 is false" do
    refute SQSPollingJob.should_poll?()
  end

  test "an enabled aws_ses SendProfile: should_poll?/0 is true" do
    create_ses_profile()
    assert SQSPollingJob.should_poll?()
  end

  test "a disabled aws_ses SendProfile alone does not satisfy the gate" do
    create_ses_profile(enabled: false)
    refute SQSPollingJob.should_poll?()
  end

  test "legacy AWS credentials with no SendProfile at all: the explicit override still polls" do
    Settings.update_setting("aws_access_key_id", "AKIALEGACY")
    Settings.update_setting("aws_secret_access_key", "legacy-secret")

    assert SQSPollingJob.should_poll?()
  end

  test "the base flags still gate independently of sender configuration" do
    create_ses_profile()

    {:ok, _} = Emails.set_sqs_polling(false)
    refute SQSPollingJob.should_poll?()
  end

  test "a bare aws_ses Integrations connection — no SendProfile, not selected — does not satisfy the gate" do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "Unreferenced SES connection")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{"access_key" => "AKIATEST", "secret_key" => "s"})

    # Nothing points at it: no SendProfile, and emails_aws_integration_uuid
    # was never set to select it — get_aws_access_key/0 falls through to
    # the (also unset) legacy Settings/env path.
    refute SQSPollingJob.should_poll?()
  end

  test "an aws_ses Integrations connection selected via emails_aws_integration_uuid (no SendProfile) satisfies the override" do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "Selected SES connection")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "s",
        "aws_region" => "eu-north-1"
      })

    {:ok, _} = Settings.update_setting("emails_aws_integration_uuid", integration_uuid)
    Emails.invalidate_aws_credentials_cache()

    assert SQSPollingJob.should_poll?()
  end

  test "an enabled non-aws_ses SendProfile (e.g. brevo_api) does not satisfy the gate" do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: true
      })

    refute SQSPollingJob.should_poll?()
  end
end
