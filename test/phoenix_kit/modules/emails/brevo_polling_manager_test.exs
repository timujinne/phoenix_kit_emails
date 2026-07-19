defmodule PhoenixKit.Modules.Emails.BrevoPollingManagerTest do
  @moduledoc """
  Unit tests for `BrevoPollingManager`'s control surface — mirrors
  `SQSPollingManager`'s contract (enable/disable/poll_now/status), backed
  by an Oban instance in `testing: :manual` mode so `Oban.insert/1`
  persists a row without actually running the job.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  test "enable_polling/0 persists the setting and inserts the first job" do
    refute Emails.brevo_events_enabled?()

    assert {:ok, %Oban.Job{}} = BrevoPollingManager.enable_polling()
    assert Emails.brevo_events_enabled?()
  end

  test "disable_polling/0 clears the setting and cancels scheduled jobs" do
    {:ok, _job} = BrevoPollingManager.enable_polling()
    assert :ok = BrevoPollingManager.disable_polling()
    refute Emails.brevo_events_enabled?()
  end

  test "set_polling_interval/1 rejects anything below 30000ms" do
    assert {:error, _} = BrevoPollingManager.set_polling_interval(29_999)
    assert Emails.get_brevo_polling_interval() == 120_000

    assert {:ok, _} = BrevoPollingManager.set_polling_interval(60_000)
    assert Emails.get_brevo_polling_interval() == 60_000
  end

  test "poll_now/0 inserts an immediate job even while polling is disabled" do
    refute Emails.brevo_events_enabled?()
    assert {:ok, %Oban.Job{}} = BrevoPollingManager.poll_now()
  end

  test "status/0 reports the sender-aware profile count" do
    assert BrevoPollingManager.status().active_brevo_profiles == 0

    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    assert BrevoPollingManager.status().active_brevo_profiles == 1
  end

  test "status/0 defaults to polling every active account (empty exclusion list)" do
    assert Emails.get_brevo_polling_excluded_integrations() == []

    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    status = BrevoPollingManager.status()
    assert status.total_brevo_accounts == 1
    assert status.polling_brevo_accounts == 1
  end

  test "status/0 reflects an excluded account: N of M drops, M does not" do
    {:ok, %{uuid: integration_uuid}} = Integrations.add_connection("brevo_api", "Brevo test")
    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo test profile",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    {:ok, _} = Emails.set_brevo_polling_excluded_integrations([integration_uuid])

    status = BrevoPollingManager.status()
    assert status.total_brevo_accounts == 1
    assert status.polling_brevo_accounts == 0
  end
end
