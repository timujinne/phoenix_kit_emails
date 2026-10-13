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

  import Phoenix.LiveViewTest

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Utils
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs, as: SesSection
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking
  alias PhoenixKit.Settings

  # Minimal socket that supports assign/3 and put_flash/3 without a live
  # connection or Endpoint.
  defp bare_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  describe "handle_event(\"assign_aws_integration\", ...)" do
    test "persists the chosen connection uuid to emails_aws_integration_uuid" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "primary")

      assert {:noreply, socket} =
               SesSection.handle_event(
                 "assign_aws_integration",
                 %{"uuid" => uuid},
                 bare_socket()
               )

      assert socket.assigns.selected_aws_integration_uuid == uuid
      assert Settings.get_setting("emails_aws_integration_uuid") == uuid
    end

    test "can be switched back to legacy (empty uuid)" do
      Settings.update_setting("emails_aws_integration_uuid", "some-uuid")

      assert {:noreply, socket} =
               SesSection.handle_event("assign_aws_integration", %{"uuid" => ""}, bare_socket())

      assert socket.assigns.selected_aws_integration_uuid == ""
      assert Settings.get_setting("emails_aws_integration_uuid") == nil
    end
  end

  describe "the section renders" do
    test "with no AWS pipeline settings at all" do
      html = render_section()

      assert html =~ "Per-account event tracking"
      refute html =~ "Inherited settings"

      # The global save form submitted params its only handler clause did not
      # match, so every click killed the LiveView. Pin its absence.
      refute html =~ "aws-settings-form"
      refute html =~ "Save AWS Settings"
    end

    test "the global aws_* values are not shown as settings even when they are set" do
      # They used to be rendered read-only in an "Inherited settings (legacy)"
      # accordion. The code fallback still reads them — poller and interceptor
      # are untouched — but an operator has no business seeing, let alone
      # reasoning about, a value only reachable from a per-account row.
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_ses_configuration_set("legacy-set")

      html = render_section()

      refute html =~ "Inherited settings"
      refute html =~ "legacy-set"

      # Still reads the globals under the hood — this is a UI removal only.
      assert Emails.get_sqs_queue_url() == "https://sqs.eu-north-1.amazonaws.com/1/q"
    end

    test "an install still on the global queue is told so, instead of 'no accounts yet'" do
      create_ses_connection_with_queue()
      {:ok, _} = Emails.set_sqs_polling(true)

      html = render_section()

      # The poller reads that queue and the tracker row above says "Active";
      # the panel used to answer "No accounts configured for event tracking
      # yet", which is the one reading of the page that sounds like nothing is
      # being collected at all.
      assert html =~ "Polling the legacy global queue"
      assert html =~ "sqs.eu-north-1.amazonaws.com/1/q"
      refute html =~ "No accounts configured for event tracking yet"

      # A pointer out of the legacy setup, not a second place to edit it.
      assert html =~ "Setup Infrastructure" or html =~ "Settings → Integrations"
      refute html =~ ~s|name="aws_sqs_queue_url"|
    end

    test "with no global queue and no accounts it still says there is nothing yet" do
      html = render_section()

      assert html =~ "No accounts configured for event tracking yet"
      refute html =~ "Polling the legacy global queue"
    end

    test "with the system off the notice names that, not a generic 'off'" do
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_sqs_polling(false)

      html = render_section()

      # Saying "polling" while collection is switched off would be the same
      # kind of lie the notice was added to remove — and a bare "off" would
      # leave the reader to work out which of five switches it is. It names the
      # module's own system switch, not "Email Tracking", which is the HEADING
      # of the section next door and carries no such toggle.
      assert html =~ "the email system is off"
      refute html =~ "Polling the legacy global queue"
    end

    test "with the system on but SES events off the notice names that switch" do
      {:ok, _} = Emails.enable_system()
      {:ok, _} = Emails.set_ses_events(false)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_sqs_polling(true)

      html = render_section()

      # The one branch between "system off" and "Tracking off" — near enough to
      # both to be worth pinning apart from them.
      assert html =~ "SES event tracking is off"
      refute html =~ "the email system is off"
      refute html =~ "Polling the legacy global queue"
    end

    test "with the system on but tracking off it points at the Tracking toggle" do
      {:ok, _} = Emails.enable_system()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_sqs_polling(false)

      html = render_section()

      assert html =~ "switch Tracking on in the row above"
    end

    test "two senders sharing the global queue are polled, and warned about" do
      {:ok, _} = Emails.enable_system()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      create_ses_connection_with_queue()
      create_ses_connection_with_queue()

      html = render_section()

      # Both senders share one queue — the poller does read it (so the notice
      # says "polling"), and the warning above it names the accounts that have
      # no queue of their own. Neither statement is the vague "collection is
      # off" this notice replaced.
      assert html =~ "Polling the legacy global queue"
      assert html =~ "Some sending accounts have no event queue of their own"
      refute html =~ "collection is off"
    end

    test "with everything on but no SES sender it says exactly that" do
      {:ok, _} = Emails.enable_system()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, _} = Emails.set_sqs_polling(true)

      html = render_section()

      assert html =~ "no enabled send profile uses Amazon SES"
    end

    test "a queue cleared while the panel is open is not called unpolled" do
      # `legacy_queue_url` is resolved once, in `update/2` behind its guard,
      # while the gate is read on every render — so the panel can be holding a
      # URL the setting no longer has. Everything else about the install is
      # fine: system on, events on, Tracking on, an SES sender in place.
      url = "https://sqs.eu-north-1.amazonaws.com/1/q"
      create_ses_connection_with_queue()
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(true)
      {:ok, _} = Emails.set_sqs_queue_url("")

      # Rendered with the assigns already in place — which is what a re-render
      # of a panel that mounted before the setting was cleared does.
      html = render_section(preloaded_assigns(legacy_queue_url: url))

      assert html =~ "no longer configured"
      refute html =~ "Polling the legacy global queue"
      refute html =~ "no enabled send profile uses Amazon SES"
    end

    test "a blank global queue setting is not a queue" do
      {:ok, _} = Emails.set_sqs_queue_url("   ")

      html = render_section()

      # `get_sqs_queue_url/0` returns whatever is stored, and a value cleared
      # through the UI is an empty string rather than a deleted row.
      refute html =~ "Polling the legacy global queue"
      assert html =~ "No accounts configured for event tracking yet"
    end

    test "the global-queue line gives way to the per-account rows" do
      {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
      {:ok, %{uuid: tracked}} = Integrations.add_connection("aws_ses", "tracked")
      {:ok, _} = Emails.set_aws_tracking(tracked, %{})

      html = render_section()

      refute html =~ "Polling the legacy global queue"
      assert html =~ "tracked"
    end

    test "one tracked account, one still on offer" do
      {:ok, %{uuid: tracked}} = Integrations.add_connection("aws_ses", "tracked")
      {:ok, _} = Integrations.add_connection("aws_ses", "spare")
      {:ok, _} = Emails.set_aws_tracking(tracked, %{})

      html = render_section()

      assert html =~ "tracked"
      assert html =~ "Setup Infrastructure"
      assert html =~ "Unassign"
      # The picker for the connection that has no tracking row yet. Its label
      # rendered as "Accounts" until the fuzzy translation behind it was
      # fixed — `gettext.extract --merge` had matched it to the table column
      # of that name, and nothing rendered this button in a test.
      assert html =~ "Add account"
    end

    test "the SQS worker tuning knobs moved here, without the Performance Tips filler" do
      html = render_section()

      assert html =~ "SQS Worker Tuning"
      assert html =~ "Max Messages Per Poll"
      assert html =~ "Visibility Timeout"
      refute html =~ "Performance Tips"
    end

    test "warns while sending still runs on the global legacy credentials" do
      {:ok, _} = Settings.update_setting("aws_access_key_id", "AKIALEGACY")

      assert render_section() =~ "legacy credentials"
    end

    test "the collection on/off line is gone, in either state" do
      {:ok, _} = Emails.set_ses_events(true)
      {:ok, _} = Emails.set_sqs_polling(false)

      refute render_section() =~ "Delivery events from Amazon SES"

      create_ses_connection_with_queue()
      {:ok, _} = Emails.set_sqs_polling(true)

      # It read should_poll?/0 — `sqs_polling_enabled` AND `eligible?/0` — which
      # is what the tracker row a centimetre above already renders decomposed
      # into "Off" vs "Idle — no integration", each with a tooltip saying what
      # to fix. One collapsed word said strictly less than the row did.
      refute render_section() =~ "Delivery events from Amazon SES"
    end
  end

  # Everything `should_poll?/0` needs on the SES side: a connection, an enabled
  # send profile pointing at it, and a queue to poll.
  defp create_ses_connection_with_queue do
    {:ok, _} = Emails.enable_system()
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "collecting")

    {:ok, _} =
      Integrations.save_setup(uuid, %{"access_key" => "AKIATEST", "secret_key" => "secret"})

    {:ok, _} =
      SendProfiles.create_send_profile(%{
        name: "SES collecting",
        integration_uuid: uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    {:ok, _} = Emails.set_sqs_queue_url("https://sqs.eu-north-1.amazonaws.com/1/q")
    uuid
  end

  defp render_section(assigns \\ %{}) do
    render_component(SesSection, Map.put(assigns, :id, "aws"),
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  # Everything `update/2` would have loaded, handed in ready-made — which is
  # what makes `update/2` skip its own load (it is guarded on
  # `:tracking_accounts`) and renders the panel as it stands after the first
  # mount, not as the database looks right now.
  defp preloaded_assigns(overrides) do
    Enum.into(overrides, %{
      mailer_status: Utils.mailer_adapter_status(),
      aws_configured: false,
      sqs_max_messages_per_poll: 10,
      sqs_visibility_timeout: 300,
      legacy_credentials?: false,
      aws_ses_connections: [],
      selected_aws_integration_uuid: "",
      accounts_awaiting_configuration: [],
      tracking_accounts: [],
      legacy_queue_url: nil,
      unassigned_connections: [],
      setting_up_account: nil
    })
  end

  describe "the panel tells its row when it changed something" do
    test "a tracking change sends the parent an update" do
      uuid = create_ses_connection_with_queue()

      socket =
        bare_socket()
        |> Phoenix.Component.assign(:parent_id, "delivery-panel")
        |> Phoenix.Component.assign(:tracking_accounts, [])
        |> Phoenix.Component.assign(:setting_up_account, nil)
        |> Phoenix.Component.assign(
          :aws_ses_connections,
          Integrations.list_connections("aws_ses", owner: :any)
        )
        |> Phoenix.Component.assign(:selected_aws_integration_uuid, "")

      {:noreply, _socket} =
        SesSection.handle_event("assign_tracking_account", %{"uuid" => uuid}, socket)

      # send_update/2 posts to the calling process, which in a unit test is us:
      # the row above the panel learns about the new account instead of waiting
      # for something else to redraw it.
      assert_received {:phoenix, :send_update,
                       {{DeliveryEventTracking, "delivery-panel"}, %{id: "delivery-panel"}}}
    end
  end

  # These handlers used to hand the payload straight to Integer.parse/1, which
  # raises on nil (neither key sent) and on an integer (a crafted event). Each
  # one must read both shapes without taking the LiveView down.
  describe "the SQS number handlers never raise on the payload shape" do
    test "update_max_messages accepts an integer" do
      assert {:noreply, socket} =
               SesSection.handle_event(
                 "update_max_messages",
                 %{"max_messages" => 5},
                 bare_socket()
               )

      assert socket.assigns.sqs_max_messages_per_poll == 5
      assert Emails.get_sqs_config().max_messages_per_poll == 5
    end

    test "update_max_messages rejects a missing value with a flash" do
      assert {:noreply, socket} =
               SesSection.handle_event("update_max_messages", %{"value" => nil}, bare_socket())

      assert socket.assigns.flash["error"]
      refute Map.has_key?(socket.assigns, :sqs_max_messages_per_poll)
    end

    test "update_visibility_timeout accepts an integer" do
      assert {:noreply, socket} =
               SesSection.handle_event(
                 "update_visibility_timeout",
                 %{"timeout" => 60},
                 bare_socket()
               )

      assert socket.assigns.sqs_visibility_timeout == 60
      assert Emails.get_sqs_config().visibility_timeout == 60
    end

    test "update_visibility_timeout rejects a missing value with a flash" do
      assert {:noreply, socket} =
               SesSection.handle_event("update_visibility_timeout", %{}, bare_socket())

      assert socket.assigns.flash["error"]
      refute Map.has_key?(socket.assigns, :sqs_visibility_timeout)
    end
  end

  # The range checks moved from `when` guards into parse_int's :min/:max, so
  # each edge is pinned: on it the value is saved, one past it is refused.
  describe "the SQS number handlers' ranges" do
    for {event, key, assign, field, baseline, inside, outside} <- [
          {"update_max_messages", "max_messages", :sqs_max_messages_per_poll,
           :max_messages_per_poll, 5, [1, 10], [0, 11]},
          {"update_visibility_timeout", "timeout", :sqs_visibility_timeout, :visibility_timeout,
           300, [30, 43_200], [29, 43_201]}
        ] do
      for value <- inside do
        test "#{event} saves #{value}, on the edge of the range" do
          assert {:noreply, socket} =
                   SesSection.handle_event(
                     unquote(event),
                     %{unquote(key) => unquote(to_string(value))},
                     bare_socket()
                   )

          assert socket.assigns[unquote(assign)] == unquote(value)
          assert Map.fetch!(Emails.get_sqs_config(), unquote(field)) == unquote(value)
        end
      end

      for value <- outside do
        test "#{event} refuses #{value}, just outside the range" do
          {:noreply, _} =
            SesSection.handle_event(
              unquote(event),
              %{unquote(key) => unquote(to_string(baseline))},
              bare_socket()
            )

          assert {:noreply, socket} =
                   SesSection.handle_event(
                     unquote(event),
                     %{unquote(key) => unquote(to_string(value))},
                     bare_socket()
                   )

          assert socket.assigns.flash["error"]
          refute Map.has_key?(socket.assigns, unquote(assign))
          assert Map.fetch!(Emails.get_sqs_config(), unquote(field)) == unquote(baseline)
        end
      end
    end
  end
end
