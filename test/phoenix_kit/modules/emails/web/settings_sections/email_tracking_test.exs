defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTrackingTest do
  @moduledoc """
  Render tests for the "Email Tracking" settings section.

  The section had no test at all when its markup was moved from the v4
  `form-control` / `label-text` idiom to daisyUI 5 `fieldset`. Those three
  classes have no rule in the shipped v5 bundle, so a regression here is
  invisible — nothing breaks, the captions simply go back to being drawn by
  `.label` alone. Hence the explicit `refute`s on the dead class names.

  This package ships no Endpoint/Router, so the component is rendered through
  `render_component/3` against the test stub endpoint rather than a live
  connection.
  """

  use PhoenixKitEmails.DataCase, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Queue
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking

  describe "the section renders" do
    test "with no email settings at all" do
      html = render_section()

      assert html =~ "System status"
      assert html =~ "Save Email Bodies"
      assert html =~ "Save Email Headers"
      assert html =~ "Emails Sampling Rate"
      assert html =~ "Email Retention Period"
      assert html =~ "Data Privacy Notice"
    end

    test "the queue switches are on the page" do
      html = render_section()

      assert html =~ ~s|name="email_tracking[queue_enabled]"|
      assert html =~ "Queue Outgoing Emails"
    end

    test "the auth-mail switch appears only while the queue itself is on" do
      # The queue is on by default, so this one has to be switched off first.
      {:ok, _} = Queue.set_enabled(false)
      refute render_section() =~ "Queue Authentication Emails Too"

      {:ok, _} = Queue.set_enabled(true)
      assert render_section() =~ "Queue Authentication Emails Too"
    end

    test "the numeric controls keep their names, bounds and events" do
      html = render_section()

      assert html =~ ~s|name="sampling_rate"|
      assert html =~ ~s|phx-blur="update_email_sampling_rate"|
      assert html =~ ~s|name="retention_days"|
      assert html =~ ~s|phx-blur="update_email_retention"|
      assert html =~ ~s|max="100"|
      assert html =~ ~s|max="365"|
    end

    test "the maintenance buttons are wired to their events" do
      html = render_section()

      assert html =~ "Run Cleanup Now"
      assert html =~ ~s|phx-click="run_cleanup_now"|
    end

    test "compression only shows up while bodies are being saved" do
      refute render_section() =~ "Compress Now"

      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      assert html =~ "Compress Email Bodies After"
      assert html =~ "Compress Now"
      assert html =~ ~s|name="compress_days"|
      assert html =~ ~s|phx-blur="update_compress_days"|
    end

    test "S3 archival is a live switch now that the uploader is wired" do
      html = render_section()

      assert html =~ "Enable S3 Archival"

      refute html =~ "In development",
             "the badge outlived the thing it described"

      refute html =~ "Not available yet"

      assert [checkbox] =
               Regex.run(~r|<input type="checkbox"[^>]*archive_to_s3[^>]*>|, html) ||
                 Regex.run(~r|<input[^>]*name="email_tracking\[archive_to_s3\]"[^>]*>|, html)

      refute checkbox =~ "disabled"
      assert checkbox =~ ~s|phx-click="toggle_s3_archival"|
    end

    test "the settings the feature needs appear only once it is switched on" do
      refute render_section() =~ ~s|name="s3_bucket"|

      {:ok, _} = Emails.set_s3_archival(true)
      html = render_section()

      assert html =~ "S3 Bucket"
      assert html =~ ~s|name="s3_bucket"|
      assert html =~ ~s|phx-blur="update_s3_bucket"|

      assert html =~ ~s|name="s3_integration"|,
             "without a credentials choice the upload falls back to ambient keys " <>
               "with no way to say so from the UI"

      assert html =~ ~s|phx-change="update_s3_integration"|

      # The schedule lives in the host's crontab, and the page has no way to
      # check it — saying so is the difference between an honest switch and one
      # that implies a job nobody configured.
      assert html =~ "ArchiveWorker"
    end
  end

  describe "daisyUI 5 form idiom" do
    test "no v4 class that the shipped bundle has no rule for" do
      html = render_section()

      refute html =~ "form-control"
      refute html =~ "label-text"
      refute html =~ "input-bordered"
      refute html =~ "input-group"
    end

    test "fields are grouped by fieldset/legend" do
      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      assert html =~ "fieldset-legend"

      # `<legend>` names the GROUP, not the field, so each control repeats the
      # caption as an aria-label — otherwise the inputs are unnamed to a
      # screen reader.
      assert html =~ ~s|aria-label="Emails Sampling Rate"|
      assert html =~ ~s|aria-label="Email Retention Period"|
      assert html =~ ~s|aria-label="Compress Email Bodies After"|
    end

    test "unit suffixes use the input/label idiom, not a half-styled join" do
      {:ok, _} = Emails.set_save_body(true)
      html = render_section()

      # daisyUI 5 draws the suffix through `.label:is(.input > *, .select > *)`:
      # the LABEL carries `.input` (one border, correct radii, a divider) and
      # the unit is a `.label` span inside it. A `.join` around a bare `.input`
      # left the suffix square and borderless — the input-group of v4 in all
      # but name.
      refute html =~ "join-item"

      for unit <- ["%", "days"] do
        assert Regex.match?(
                 ~r|<label[^>]*\bclass="[^"]*\binput\b[^"]*"[^>]*>.*?<span class="label">\s*#{Regex.escape(unit)}\s*</span>|s,
                 html
               ),
               "expected an .input label wrapping the #{unit} suffix"
      end

      # `.fieldset` is a grid: a width-less flex child stretches the column
      # instead of hugging its input. Read out of the class list rather than
      # matched as a string — the order the classes are written in is not the
      # thing under test.
      input_labels =
        ~r|<label[^>]*\bclass="([^"]*)"|
        |> Regex.scan(html)
        |> Enum.map(fn [_, classes] -> String.split(classes) end)
        |> Enum.filter(&("input" in &1))

      assert length(input_labels) == 3
      assert Enum.all?(input_labels, &("w-32" in &1))
    end
  end

  defp render_section do
    render_component(
      PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking,
      %{id: "email-tracking"},
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  describe "the S3 handlers accept the payload LiveView actually sends" do
    # `phx-blur` and a form-less `phx-change` send the element's value under
    # "value", not under the element's name. Reading only the name key meant
    # every blur wrote `""` — which, since blank clears, deleted the bucket the
    # operator had just typed. Both shapes are asserted so neither regresses.
    setup do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          email_archive_to_s3: false,
          email_s3_bucket: "",
          email_s3_integration: ""
        }
      }

      %{socket: socket}
    end

    test "the bucket is saved from the \"value\" key", %{socket: socket} do
      {:noreply, socket} =
        EmailTracking.handle_event("update_s3_bucket", %{"value" => "archive-bucket"}, socket)

      assert socket.assigns.email_s3_bucket == "archive-bucket"
      assert Emails.get_s3_bucket() == "archive-bucket"
    end

    test "the bucket is saved from the named key too", %{socket: socket} do
      {:noreply, _socket} =
        EmailTracking.handle_event("update_s3_bucket", %{"s3_bucket" => "named-bucket"}, socket)

      assert Emails.get_s3_bucket() == "named-bucket"
    end

    test "a blank value clears the bucket rather than failing", %{socket: socket} do
      {:ok, _} = Emails.set_s3_bucket("to-be-cleared")

      {:noreply, socket} =
        EmailTracking.handle_event("update_s3_bucket", %{"value" => "  "}, socket)

      assert socket.assigns.email_s3_bucket == ""
      assert Emails.get_s3_bucket() == nil
    end

    test "the connection is saved from the \"value\" key", %{socket: socket} do
      {:noreply, socket} =
        EmailTracking.handle_event("update_s3_integration", %{"value" => "some-uuid"}, socket)

      assert socket.assigns.email_s3_integration == "some-uuid"
      assert Emails.get_s3_integration() == "some-uuid"
    end

    test "an empty choice means the ambient credentials", %{socket: socket} do
      {:ok, _} = Emails.set_s3_integration("some-uuid")

      {:noreply, _socket} =
        EmailTracking.handle_event("update_s3_integration", %{"value" => ""}, socket)

      assert Emails.get_s3_integration() == nil
    end

    test "the toggle flips the setting", %{socket: socket} do
      {:noreply, socket} = EmailTracking.handle_event("toggle_s3_archival", %{}, socket)

      assert socket.assigns.email_archive_to_s3 == true
      assert Emails.get_config().archive_to_s3 == true
    end
  end

  # These handlers used to hand the payload straight to Integer.parse/1, which
  # raises on nil (neither key sent) and on an integer (a crafted event).
  describe "the number handlers never raise on the payload shape" do
    defp number_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}}
      }
    end

    for {event, key, value, assign} <- [
          {"update_email_sampling_rate", "sampling_rate", 50, :email_sampling_rate},
          {"update_email_retention", "retention_days", 30, :email_retention_days},
          {"update_compress_days", "compress_days", 14, :email_compress_body}
        ] do
      test "#{event} accepts an integer" do
        assert {:noreply, socket} =
                 EmailTracking.handle_event(
                   unquote(event),
                   %{unquote(key) => unquote(value)},
                   number_socket()
                 )

        assert socket.assigns[unquote(assign)] == unquote(value)
        refute socket.assigns.flash["error"]
      end

      test "#{event} rejects a missing value with a flash" do
        assert {:noreply, socket} =
                 EmailTracking.handle_event(unquote(event), %{"value" => nil}, number_socket())

        assert socket.assigns.flash["error"]
        refute Map.has_key?(socket.assigns, unquote(assign))
      end
    end
  end

  # The range checks moved from `when` guards into parse_int's :min/:max, so
  # each edge is pinned: on it the value is saved, one past it is refused.
  describe "the number handlers' ranges" do
    defp range_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}}
      }
    end

    defp stored(:email_sampling_rate), do: Emails.get_sampling_rate()
    defp stored(:email_retention_days), do: Emails.get_retention_days()
    defp stored(:email_compress_body), do: Emails.get_config().compress_after_days

    for {event, key, assign, baseline, inside, outside} <- [
          {"update_email_sampling_rate", "sampling_rate", :email_sampling_rate, 50, [0, 100],
           [-1, 101]},
          {"update_email_retention", "retention_days", :email_retention_days, 90, [1, 365],
           [0, 366]},
          {"update_compress_days", "compress_days", :email_compress_body, 30, [7, 365], [6, 366]}
        ] do
      for value <- inside do
        test "#{event} saves #{value}, on the edge of the range" do
          assert {:noreply, socket} =
                   EmailTracking.handle_event(
                     unquote(event),
                     %{unquote(key) => unquote(to_string(value))},
                     range_socket()
                   )

          assert socket.assigns[unquote(assign)] == unquote(value)
          assert stored(unquote(assign)) == unquote(value)
        end
      end

      for value <- outside do
        test "#{event} refuses #{value}, just outside the range" do
          {:noreply, _} =
            EmailTracking.handle_event(
              unquote(event),
              %{unquote(key) => unquote(to_string(baseline))},
              range_socket()
            )

          assert {:noreply, socket} =
                   EmailTracking.handle_event(
                     unquote(event),
                     %{unquote(key) => unquote(to_string(value))},
                     range_socket()
                   )

          assert socket.assigns.flash["error"]
          refute Map.has_key?(socket.assigns, unquote(assign))
          assert stored(unquote(assign)) == unquote(baseline)
        end
      end
    end
  end
end
