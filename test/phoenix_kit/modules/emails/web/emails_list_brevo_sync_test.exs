defmodule PhoenixKit.Modules.Emails.Web.EmailsListBrevoSyncTest do
  @moduledoc """
  The emails list's row-menu "sync_log" handler routes to
  `BrevoOnDemandSync` for a `provider: "brevo_api"` log — same branch as
  `Details.handle_event("sync_status", ...)`, exercised the same way
  (hand-built socket, no Endpoint/Router in this standalone suite).
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Web.Emails, as: EmailsListLive
  alias PhoenixKitEmails.Test.Repo

  @stub PhoenixKit.Modules.Emails.BrevoPollingJobTest.Stub

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp bare_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp create_brevo_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com"
      })

    :ok
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

  test "sync_log routes a brevo_api row to the Brevo branch and updates the row in place" do
    create_brevo_profile()
    message_id = "<list-sync-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "delivered",
      "messageId" => message_id
    }

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => [event]}) end)

    socket = bare_socket(%{logs: [log]})

    assert {:noreply, updated} =
             EmailsListLive.handle_event("sync_log", %{"uuid" => log.uuid}, socket)

    assert updated.assigns.flash["info"] =~ "1"
    [updated_log] = updated.assigns.logs
    assert updated_log.status == "delivered"
  end

  test "sync_log for a brevo_api row with no active integration flashes honestly, no crash" do
    message_id = "<list-sync-noint-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    socket = bare_socket(%{logs: [log]})

    assert {:noreply, updated} =
             EmailsListLive.handle_event("sync_log", %{"uuid" => log.uuid}, socket)

    assert updated.assigns.flash["error"] =~ "No active Brevo integration"
  end
end
