defmodule PhoenixKit.Modules.Emails.Web.DetailsBrevoSyncTest do
  @moduledoc """
  The Details page's "sync_status" handler routes to
  `BrevoOnDemandSync` for a `provider: "brevo_api"` log instead of the
  SES-only `Emails.sync_email_status/1` path. Exercised directly against
  a hand-built socket, same approach as
  `AmazonSesSqsTest` — this package ships no Endpoint/Router, so there's
  no `Phoenix.LiveViewTest` harness available standalone.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Web.Details
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

  test "a brevo_api log's sync_status flashes the events-received count, not the SES path" do
    create_brevo_profile()
    message_id = "<details-sync-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    event = %{
      "date" => "2026-07-19T10:00:00Z",
      "email" => "recipient@example.com",
      "event" => "delivered",
      "messageId" => message_id
    }

    Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => [event]}) end)

    socket = bare_socket(%{email_log: log, syncing: false, email_uuid: log.uuid})

    assert {:noreply, updated} = Details.handle_event("sync_status", %{}, socket)
    assert updated.assigns.flash["info"] =~ "1"
  end

  test "a brevo_api log with no active integration gets an honest flash, no crash" do
    message_id = "<details-sync-noint-#{System.unique_integer([:positive])}@example.com>"
    log = create_brevo_log(message_id)

    socket = bare_socket(%{email_log: log, syncing: false, email_uuid: log.uuid})

    assert {:noreply, updated} = Details.handle_event("sync_status", %{}, socket)
    assert updated.assigns.flash["error"] =~ "No active Brevo integration"
  end
end
