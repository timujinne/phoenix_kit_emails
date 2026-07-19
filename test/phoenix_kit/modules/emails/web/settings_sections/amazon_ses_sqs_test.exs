defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqsTest do
  @moduledoc """
  Unit tests for the "Amazon SES & SQS" settings section's SES-credentials
  source selector (ported from the old routable Settings LiveView, Stage
  B3 / Stage 1 A5). This package ships no Endpoint/Router, so there's no
  `Phoenix.LiveViewTest` harness available standalone — the callback is
  exercised directly against a hand-built socket instead, same as it would
  run inside the real live_component process.
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs, as: SesSection
  alias PhoenixKit.Settings

  # Minimal socket that supports assign/3 and put_flash/3 without a live
  # connection or Endpoint.
  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  describe "handle_event(\"select_aws_integration\", ...)" do
    test "persists the chosen connection uuid to emails_aws_integration_uuid" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "primary")

      assert {:noreply, socket} =
               SesSection.handle_event(
                 "select_aws_integration",
                 %{"uuid" => uuid},
                 bare_socket()
               )

      assert socket.assigns.selected_aws_integration_uuid == uuid
      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
    end

    test "can be switched back to legacy (empty uuid)" do
      Settings.update_setting("emails_aws_integration_uuid", "some-uuid")

      assert {:noreply, socket} =
               SesSection.handle_event("select_aws_integration", %{"uuid" => ""}, bare_socket())

      assert socket.assigns.selected_aws_integration_uuid == ""
      assert Settings.get_setting("emails_aws_integration_uuid") == nil
    end
  end
end
