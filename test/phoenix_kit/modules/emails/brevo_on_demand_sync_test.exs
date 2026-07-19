defmodule PhoenixKit.Modules.Emails.BrevoOnDemandSyncTest do
  @moduledoc """
  The "sync now" button's Brevo branch — a targeted, single-`messageId`
  fetch, distinct from `BrevoPollingJob`'s broad poll. Stubbed via
  `Req.Test`, same stub name as `BrevoPollingJob`'s tests (see
  `config/test.exs`).
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoOnDemandSync
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKitEmails.Test.Repo

  @stub PhoenixKit.Modules.Emails.BrevoPollingJobTest.Stub

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp create_brevo_profile(api_key \\ "test-api-key") do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => api_key})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    integration_uuid
  end

  defp create_brevo_log(message_id) do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "brevo_api",
        status: "sent",
        aws_message_id: message_id
      })
      |> Repo.insert()

    log
  end

  test "queries Brevo filtered to exactly this log's messageId" do
    create_brevo_profile()
    message_id = "<sync-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(test_pid, {:queried, query["messageId"]})
      Req.Test.json(conn, %{"events" => []})
    end)

    assert {:ok, %{events_processed: 0}} = BrevoOnDemandSync.sync(log)
    assert_received {:queried, ^message_id}
  end

  test "processes returned events through the same pipeline as the poller" do
    create_brevo_profile()
    message_id = "<sync2-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "delivered",
      "messageId" => message_id
    }

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => [event]}) end)

    assert {:ok, %{events_processed: 1}} = BrevoOnDemandSync.sync(log)
    assert Repo.get(Log, log.uuid).status == "delivered"
  end

  test "no active Brevo integration: honest error, no HTTP attempted" do
    message_id = "<no-integration-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    # Not stubbed — must never reach BrevoClient.
    assert {:error, reason} = BrevoOnDemandSync.sync(log)
    assert reason =~ "No active Brevo integration"
  end

  test "a log with no recoverable message id errors without touching the network" do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "brevo_api",
        status: "sent"
      })
      |> Repo.insert()

    assert {:error, reason} = BrevoOnDemandSync.sync(log)
    assert reason =~ "no recoverable Brevo message id"
  end

  test "bypasses brevo_events_enabled (a manual request, not the background poll)" do
    create_brevo_profile()
    {:ok, _} = Emails.set_brevo_events_enabled(false)

    message_id = "<bypass-toggle-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => []}) end)

    assert {:ok, %{events_processed: 0}} = BrevoOnDemandSync.sync(log)
  end

  test "bypasses the per-integration polling opt-out (a manual request, not the background poll)" do
    integration_uuid = create_brevo_profile()
    {:ok, _} = Emails.set_brevo_polling_excluded_integrations([integration_uuid])

    message_id = "<bypass-exclusion-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => []}) end)

    assert {:ok, %{events_processed: 0}} = BrevoOnDemandSync.sync(log)
  end

  test "system disabled: honest error, no HTTP attempted" do
    {:ok, _} = Emails.disable_system()
    message_id = "<system-disabled-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    assert {:error, reason} = BrevoOnDemandSync.sync(log)
    assert reason =~ "disabled"
  end
end
