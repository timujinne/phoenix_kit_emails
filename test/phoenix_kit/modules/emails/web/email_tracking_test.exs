defmodule PhoenixKit.Modules.Emails.Web.EmailTrackingTest do
  @moduledoc """
  The standalone tracking page is no longer in `admin_tabs/0`, but it is
  still a LiveView and still the only UI that writes `email_ses_events`
  directly. The retention field on it used to resubmit the previous
  assign via `phx-value-retention_days`, so blur could not change the
  stored number. That wiring is what this file locks in.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Web.EmailTracking

  describe "update_email_tracking_retention" do
    test "persists the typed blur value, not a leftover assign" do
      {:ok, _} = Emails.set_retention_days(90)

      socket = bare_socket(%{email_tracking_retention_days: 90})

      # What LiveView actually sends for phx-blur: the input's current value.
      # The old template stuffed the assign into phx-value-retention_days, so
      # the handler never saw the number the operator typed.
      assert {:noreply, socket} =
               EmailTracking.handle_event(
                 "update_email_tracking_retention",
                 %{"value" => "42"},
                 socket
               )

      assert socket.assigns.email_tracking_retention_days == 42
      assert Emails.get_retention_days() == 42
    end

    test "also accepts a named retention_days field" do
      {:ok, _} = Emails.set_retention_days(90)

      socket = bare_socket(%{email_tracking_retention_days: 90})

      assert {:noreply, socket} =
               EmailTracking.handle_event(
                 "update_email_tracking_retention",
                 %{"retention_days" => "180", "value" => "180"},
                 socket
               )

      assert socket.assigns.email_tracking_retention_days == 180
      assert Emails.get_retention_days() == 180
    end

    test "rejects a number outside 1..365" do
      {:ok, _} = Emails.set_retention_days(90)

      socket = bare_socket(%{email_tracking_retention_days: 90})

      assert {:noreply, socket} =
               EmailTracking.handle_event(
                 "update_email_tracking_retention",
                 %{"value" => "400"},
                 socket
               )

      assert socket.assigns.email_tracking_retention_days == 90
      assert Emails.get_retention_days() == 90
    end
  end

  describe "render" do
    test "retention control is a named fieldset input with the v5 unit suffix" do
      html =
        render_component(
          &EmailTracking.render/1,
          %{
            email_tracking_enabled: true,
            email_tracking_save_body: true,
            email_tracking_ses_events: true,
            email_tracking_retention_days: 90
          },
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      assert html =~ "fieldset-legend"
      assert html =~ ~s|name="retention_days"|
      assert html =~ ~s|aria-label="Email Retention Period"|
      assert html =~ ~s|phx-blur="update_email_tracking_retention"|
      refute html =~ "phx-value-retention_days"
      refute html =~ "input-group"

      assert Regex.match?(
               ~r|<label[^>]*\bclass="[^"]*\binput\b[^"]*"[^>]*>.*?<span class="label">\s*days\s*</span>|s,
               html
             )
    end
  end

  defp bare_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  # `|| ""` covered a missing value but not an integer from a crafted event,
  # which Integer.parse/1 raised on just the same.
  describe "update_email_tracking_retention payload shapes" do
    test "accepts an integer" do
      {:ok, _} = Emails.set_retention_days(90)

      assert {:noreply, socket} =
               EmailTracking.handle_event(
                 "update_email_tracking_retention",
                 %{"value" => 42},
                 bare_socket(%{email_tracking_retention_days: 90})
               )

      assert socket.assigns.email_tracking_retention_days == 42
      assert Emails.get_retention_days() == 42
    end

    test "rejects a missing value with a flash" do
      assert {:noreply, socket} =
               EmailTracking.handle_event(
                 "update_email_tracking_retention",
                 %{"value" => nil},
                 bare_socket(%{email_tracking_retention_days: 90})
               )

      assert socket.assigns.flash["error"]
      assert socket.assigns.email_tracking_retention_days == 90
    end
  end

  describe "update_email_tracking_retention range" do
    for value <- [1, 365] do
      test "saves #{value}, on the edge of the range" do
        {:ok, _} = Emails.set_retention_days(90)

        assert {:noreply, socket} =
                 EmailTracking.handle_event(
                   "update_email_tracking_retention",
                   %{"value" => unquote(to_string(value))},
                   bare_socket(%{email_tracking_retention_days: 90})
                 )

        assert socket.assigns.email_tracking_retention_days == unquote(value)
        assert Emails.get_retention_days() == unquote(value)
      end
    end

    for value <- [0, 366] do
      test "refuses #{value}, just outside the range" do
        {:ok, _} = Emails.set_retention_days(90)

        assert {:noreply, socket} =
                 EmailTracking.handle_event(
                   "update_email_tracking_retention",
                   %{"value" => unquote(to_string(value))},
                   bare_socket(%{email_tracking_retention_days: 90})
                 )

        assert socket.assigns.flash["error"]
        assert socket.assigns.email_tracking_retention_days == 90
        assert Emails.get_retention_days() == 90
      end
    end
  end
end
