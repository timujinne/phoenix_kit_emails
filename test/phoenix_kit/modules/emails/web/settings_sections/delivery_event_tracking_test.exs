defmodule PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTrackingTest do
  @moduledoc """
  Unit tests for the unified "Delivery event tracking" admin panel (task
  #56 P2, spec §5) — `update/2`'s registry-driven rows (one per state)
  and every `handle_event/3` action. Like `AmazonSesSqsTest`, this
  package ships no Endpoint/Router, so there's no `Phoenix.LiveViewTest`
  harness — callbacks are exercised directly against a hand-built socket.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKit.Modules.Emails.BrevoPollingManager
  alias PhoenixKit.Modules.Emails.SQSPollingJob
  alias PhoenixKit.Modules.Emails.SQSPollingManager
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs, as: SesSection
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.DeliveryEventTracking, as: Panel
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking
  alias PhoenixKitEmails.Test.Repo

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    :ok
  end

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  # Everything SES eligibility needs: a sender pointed at an aws_ses
  # integration AND a queue to poll (callers below use this to mean "the SES
  # tracker is eligible now").
  defp create_ses_profile do
    {:ok, _} = Emails.set_sqs_queue_url("https://sqs.example.com/queue")

    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("aws_ses", "SES #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(integration_uuid, %{
        "access_key" => "AKIATEST",
        "secret_key" => "secret"
      })

    {:ok, _profile} =
      SendProfiles.create_send_profile(%{
        name: "SES profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "aws_ses",
        from_email: "sender@example.com",
        enabled: true
      })

    :ok
  end

  defp create_brevo_profile do
    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => "test-key"})

    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: true
      })

    profile
  end

  defp row_for(rows, provider_kind), do: Enum.find(rows, &(&1.provider_kind == provider_kind))

  # This package ships no Endpoint, so `render_component/3` is the only way to
  # get real HTML out of a section — including the nested live_component an
  # expanded row mounts, which no socket-level assertion can reach.
  defp render_panel(expanded \\ MapSet.new()) do
    render_component(Panel, %{id: "panel", expanded: expanded},
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  test "the SES processing switch reconciles the chain without changing the polling preference" do
    create_ses_profile()
    {:ok, job} = SQSPollingManager.enable_polling()
    {:ok, socket} = EmailTracking.update(%{id: "email-tracking"}, bare_socket())

    {:noreply, socket} = EmailTracking.handle_event("toggle_email_ses_events", %{}, socket)
    refute Emails.ses_events_enabled?()
    assert SQSPollingManager.enabled?()
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"

    {:noreply, _socket} = EmailTracking.handle_event("toggle_email_ses_events", %{}, socket)
    assert Emails.ses_events_enabled?()
    assert SQSPollingManager.enabled?()

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == ^inspect(SQSPollingJob) and j.state in ["available", "scheduled"]
             )
           )
  end

  describe "update/2 — the registry-driven rows" do
    test "one row per registered tracker, :off by default (nothing enabled)" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert length(socket.assigns.rows) == 2
      assert row_for(socket.assigns.rows, "aws_ses").state == :off
      assert row_for(socket.assigns.rows, "brevo_api").state == :off
    end

    test "enabled but no matching integration: :idle_no_integration" do
      {:ok, _} = Emails.set_sqs_polling(true)

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "aws_ses").state == :idle_no_integration
    end

    test "enabled + eligible + a chain queued: :active" do
      create_ses_profile()
      {:ok, %Oban.Job{}} = SQSPollingManager.enable_polling()

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      row = row_for(socket.assigns.rows, "aws_ses")
      assert row.state == :active
      assert row.pending_jobs > 0
    end

    test "enabled + eligible but zero queued jobs: :stalled" do
      create_ses_profile()
      {:ok, _} = Emails.set_sqs_polling(true)

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "aws_ses").state == :stalled
    end

    test "both rows expose an accounts list — SES is multi-account too now" do
      create_brevo_profile()

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "brevo_api").accounts != nil
      # Empty, not nil: this deployment has no aws_ses send profile, but the
      # tracker implements the callback, so the column renders a real (if
      # empty) list rather than the "—" a tracker without it gets.
      assert row_for(socket.assigns.rows, "aws_ses").accounts == []
    end
  end

  describe "handle_event(\"toggle_tracking\", ...)" do
    test "turns SES polling on, then off again" do
      refute Emails.sqs_polling_enabled?()

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, bare_socket())

      assert Emails.sqs_polling_enabled?()
      assert row_for(socket.assigns.rows, "aws_ses").enabled

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, socket)

      refute Emails.sqs_polling_enabled?()
      refute row_for(socket.assigns.rows, "aws_ses").enabled
    end

    test "turns Brevo polling on" do
      refute Emails.brevo_events_enabled?()

      assert {:noreply, _socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "brevo_api"}, bare_socket())

      assert Emails.brevo_events_enabled?()
    end

    # The managers' enable_polling/0 inserts a chain without consulting
    # eligible?/0, so the toggle used to leave a queued job for a tracker
    # with nothing to poll — the panel reading "Idle — no integration"
    # beside a non-zero Queued count, until (or unless) the reconcile Cron
    # ticked. The toggle now reconciles, which is what owns that decision.
    test "turning tracking on for an INELIGIBLE tracker leaves no chain behind" do
      refute SQSPollingManager.eligible?()

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, bare_socket())

      assert Emails.sqs_polling_enabled?()

      worker = SQSPollingJob.worker_name()

      refute Repo.exists?(
               from(j in Oban.Job,
                 where: j.worker == ^worker and j.state in ["available", "scheduled"]
               )
             )

      row = row_for(socket.assigns.rows, "aws_ses")
      assert row.state == :idle_no_integration
      assert row.pending_jobs == 0
    end

    # The mirror case: an eligible tracker still gets its chain started.
    test "turning tracking on for an eligible tracker starts a chain" do
      create_ses_profile()

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, bare_socket())

      row = row_for(socket.assigns.rows, "aws_ses")
      assert row.state == :active
      assert row.pending_jobs >= 1
    end

    # Turning tracking off used to leave the queued job in place until the
    # next Cron tick; the toggle's own reconcile cancels it immediately.
    test "turning tracking off cancels the queued chain immediately" do
      create_ses_profile()
      {:ok, %Oban.Job{}} = SQSPollingManager.enable_polling()

      assert {:noreply, socket} =
               Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, bare_socket())

      refute Emails.sqs_polling_enabled?()

      row = row_for(socket.assigns.rows, "aws_ses")
      assert row.state == :off
      assert row.pending_jobs == 0
    end
  end

  describe "handle_event(\"poll_now\", ...)" do
    test "inserts an immediate job for the SES worker, and rebuilds rows AFTER the insert" do
      create_ses_profile()

      assert {:noreply, socket} =
               Panel.handle_event("poll_now", %{"provider" => "aws_ses"}, bare_socket())

      worker = SQSPollingJob.worker_name()
      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))

      # Regression for P2 dual-review follow-up (Kimi): rows used to be
      # rebuilt BEFORE poll_now/0's insert, so a Stalled/Queued=0 row
      # stayed stale in the very socket this handler returned.
      assert row_for(socket.assigns.rows, "aws_ses").pending_jobs >= 1
    end

    test "inserts an immediate job for the Brevo worker, and rebuilds rows AFTER the insert" do
      create_brevo_profile()

      assert {:noreply, socket} =
               Panel.handle_event("poll_now", %{"provider" => "brevo_api"}, bare_socket())

      worker = BrevoPollingJob.worker_name()
      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
      assert row_for(socket.assigns.rows, "brevo_api").pending_jobs >= 1
    end

    # poll_now/0 forces a cycle past the toggle, never past eligibility —
    # so for an ineligible tracker the job it queued could only ever run,
    # fail its own gate, and do nothing, while the flash said "poll
    # triggered". Refuse instead of reporting a success that never happens.
    test "refuses, with an explanation, for a tracker that has no event source" do
      refute SQSPollingManager.eligible?()

      assert {:noreply, socket} =
               Panel.handle_event("poll_now", %{"provider" => "aws_ses"}, bare_socket())

      assert socket.assigns.flash["error"]

      worker = SQSPollingJob.worker_name()
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
    end
  end

  describe "handle_event(\"restart\", ...)" do
    test "reconciles a stalled tracker back to a queued chain" do
      create_ses_profile()
      {:ok, _} = Emails.set_sqs_polling(true)

      worker = SQSPollingJob.worker_name()
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))

      assert {:noreply, socket} =
               Panel.handle_event("restart", %{"provider" => "aws_ses"}, bare_socket())

      assert Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker))
      assert row_for(socket.assigns.rows, "aws_ses").state == :active
    end

    test "a tracker that should not run stays stopped (:not_running, not an error)" do
      assert {:noreply, socket} =
               Panel.handle_event("restart", %{"provider" => "aws_ses"}, bare_socket())

      assert socket.assigns.flash["error"] == nil
    end
  end

  describe "handle_event(\"update_interval\", ...)" do
    test "accepts a valid interval" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "5000"},
                 bare_socket()
               )

      assert Emails.get_sqs_config().polling_interval_ms == 5_000
      assert socket.assigns.flash["error"] == nil
    end

    test "rejects a value below the tracker's own minimum" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "10"},
                 bare_socket()
               )

      # Regression for P2 dual-review fix 4/5: the manager's own reason
      # string used to get double-quoted by inspect/1 before landing in
      # the flash.
      assert error = socket.assigns.flash["error"]
      refute error =~ "\""
    end

    test "rejects a non-numeric value without raising" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "not-a-number"},
                 bare_socket()
               )

      assert socket.assigns.flash["error"]
    end
  end

  describe "handle_event(\"toggle_account\", ...)" do
    test "excludes then re-includes a Brevo account from polling" do
      create_brevo_profile()
      [{uuid, _name, true}] = BrevoPollingManager.accounts()

      assert {:noreply, socket} =
               Panel.handle_event(
                 "toggle_account",
                 %{"provider" => "brevo_api", "uuid" => uuid},
                 bare_socket()
               )

      assert [{^uuid, _name, false}] = row_for(socket.assigns.rows, "brevo_api").accounts

      assert {:noreply, socket} =
               Panel.handle_event(
                 "toggle_account",
                 %{"provider" => "brevo_api", "uuid" => uuid},
                 socket
               )

      assert [{^uuid, _name, true}] = row_for(socket.assigns.rows, "brevo_api").accounts
    end
  end

  describe "an unknown provider_kind (P2 dual-review fix 5b)" do
    test "every action returns {:noreply, socket} instead of raising" do
      socket = bare_socket()

      for {event, params} <- [
            {"toggle_tracking", %{"provider" => "does-not-exist"}},
            {"poll_now", %{"provider" => "does-not-exist"}},
            {"restart", %{"provider" => "does-not-exist"}},
            {"update_interval", %{"provider" => "does-not-exist", "interval" => "5000"}},
            {"toggle_account", %{"provider" => "does-not-exist", "uuid" => "any-uuid"}}
          ] do
        assert {:noreply, %Phoenix.LiveView.Socket{}} = Panel.handle_event(event, params, socket)
      end
    end
  end

  describe "the accounts dialog" do
    test "opening targets a provider that has an account list" do
      create_brevo_profile()
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("open_accounts", %{"provider" => "brevo_api"}, socket)

      assert opened.assigns.accounts_for == "brevo_api"

      {:noreply, closed} = Panel.handle_event("close_accounts", %{}, opened)
      assert closed.assigns.accounts_for == nil
    end

    test "a provider whose account list is empty never opens the dialog" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      # SES starts with no accounts at all — the trigger renders disabled, and
      # the handler must agree with it rather than open an empty dialog.
      assert row_for(socket.assigns.rows, "aws_ses").accounts == []

      {:noreply, untouched} =
        Panel.handle_event("open_accounts", %{"provider" => "aws_ses"}, socket)

      assert untouched.assigns.accounts_for == nil
    end

    test "a forged provider never opens the dialog" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, untouched} =
        Panel.handle_event("open_accounts", %{"provider" => "not_a_tracker"}, socket)

      assert untouched.assigns.accounts_for == nil
    end

    test "a dialog left open over a vanished row closes itself on the next update" do
      create_brevo_profile()
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())
      socket = Phoenix.Component.assign(socket, :accounts_for, "gone_provider")

      {:ok, refreshed} = Panel.update(%{id: "panel"}, socket)

      assert refreshed.assigns.accounts_for == nil
    end

    test "the open dialog resolves to a row, and toggling keeps it open" do
      create_brevo_profile()
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("open_accounts", %{"provider" => "brevo_api"}, socket)

      assert opened.assigns.accounts_row.provider_kind == "brevo_api"
      [{uuid, _name, _polled?}] = opened.assigns.accounts_row.accounts

      {:noreply, toggled} =
        Panel.handle_event(
          "toggle_account",
          %{"provider" => "brevo_api", "uuid" => uuid},
          opened
        )

      # The dialog stays open on a fresh row — the whole point of the rework.
      assert toggled.assigns.accounts_for == "brevo_api"
      assert toggled.assigns.accounts_row.provider_kind == "brevo_api"
    end

    test "a row that disappears under an open dialog closes it in the handler, not just in update/2" do
      profile = create_brevo_profile()
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("open_accounts", %{"provider" => "brevo_api"}, socket)

      [{uuid, _name, _polled?}] = opened.assigns.accounts_row.accounts

      # Somebody disables the last enabled Brevo profile in the section next
      # door; the account list this dialog renders from goes empty. The next
      # toggle must not render against a row that is no longer there.
      {:ok, _} = SendProfiles.update_send_profile(profile, %{enabled: false})

      {:noreply, refreshed} =
        Panel.handle_event(
          "toggle_account",
          %{"provider" => "brevo_api", "uuid" => uuid},
          opened
        )

      assert refreshed.assigns.accounts_row == nil
      assert refreshed.assigns.accounts_for == nil
    end
  end

  describe "the expandable row" do
    test "starts collapsed, expands, and collapses again" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())
      assert MapSet.size(socket.assigns.expanded) == 0

      {:noreply, opened} =
        Panel.handle_event("toggle_expand", %{"provider" => "aws_ses"}, socket)

      assert MapSet.member?(opened.assigns.expanded, "aws_ses")
      # Only the row that was clicked.
      refute MapSet.member?(opened.assigns.expanded, "brevo_api")

      {:noreply, closed} =
        Panel.handle_event("toggle_expand", %{"provider" => "aws_ses"}, opened)

      refute MapSet.member?(closed.assigns.expanded, "aws_ses")
    end

    test "a forged provider never expands anything" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, untouched} =
        Panel.handle_event("toggle_expand", %{"provider" => "not_a_tracker"}, socket)

      assert MapSet.size(untouched.assigns.expanded) == 0
    end

    # The reason this is an assign and not `<details>`/a daisyUI collapse: the
    # row must survive every rebuild of the data under it.
    test "an expanded row survives a data refresh" do
      create_ses_profile()
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("toggle_expand", %{"provider" => "aws_ses"}, socket)

      {:noreply, after_toggle} =
        Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, opened)

      assert MapSet.member?(after_toggle.assigns.expanded, "aws_ses")

      {:ok, refreshed} = Panel.update(%{id: "panel"}, after_toggle)
      assert MapSet.member?(refreshed.assigns.expanded, "aws_ses")
    end

    test "an expanded provider that no longer has a row is dropped" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())
      socket = Phoenix.Component.assign(socket, :expanded, MapSet.new(["gone_provider"]))

      {:ok, refreshed} = Panel.update(%{id: "panel"}, socket)

      assert MapSet.size(refreshed.assigns.expanded) == 0
    end

    test "each row carries the settings component its tracker names" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      assert row_for(socket.assigns.rows, "aws_ses").settings_component == SesSection
      assert row_for(socket.assigns.rows, "brevo_api").settings_component == nil
    end
  end

  describe "the rendered panel" do
    test "collapsed: no provider settings, and no Interval column" do
      html = render_panel()

      refute html =~ "Per-account event tracking"
      refute html =~ "SQS Worker Tuning"
      # The interval moved into the expanded row; the column it used to own is
      # gone, header included.
      refute html =~ ">Interval<"
    end

    test "expanded SES: the whole former \"Amazon SES & SQS\" section renders inline" do
      # One account already tracked (so its row and Setup Infrastructure
      # render) and one still unassigned (so the "Add account" picker does).
      {:ok, %{uuid: tracked}} = Integrations.add_connection("aws_ses", "tracked")
      {:ok, _} = Integrations.add_connection("aws_ses", "spare")
      {:ok, _} = Emails.set_aws_tracking(tracked, %{})

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("toggle_expand", %{"provider" => "aws_ses"}, socket)

      html = render_panel(opened.assigns.expanded)

      # The nested live_component actually renders — the whole point of
      # settings_component/0, and the thing a socket-level assertion cannot see.
      assert html =~ "SES credentials source"
      assert html =~ "Per-account event tracking"
      assert html =~ "Setup Infrastructure"
      assert html =~ "Unassign"
      assert html =~ "Add account"
      assert html =~ "SQS Worker Tuning"
      # Generic, panel-owned, next to the SQS knobs.
      assert html =~ "Polling interval"
      # Deleted for good.
      refute html =~ "Performance Tips"
      refute html =~ "Inherited settings"
    end

    test "the expanded row's forms are daisyUI 5, not v4 classes that style nothing" do
      {:ok, %{uuid: tracked}} = Integrations.add_connection("aws_ses", "tracked")
      {:ok, _} = Emails.set_aws_tracking(tracked, %{})

      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("toggle_expand", %{"provider" => "aws_ses"}, socket)

      html = render_panel(opened.assigns.expanded)

      # `form-control`, `label-text` and `label-text-alt` have no rule at all in
      # the shipped daisyUI 5 bundle, so markup carrying them is unstyled, not
      # merely old-fashioned. One render covers both templates: the SES panel
      # is nested inside this one.
      refute html =~ "form-control"
      refute html =~ "label-text"

      assert html =~ "fieldset-legend"
      # `.fieldset` is a grid, so the interval editor has to say it wants to
      # hug its 8rem input instead of spanning the column.
      assert html =~ "join w-fit"
      assert html =~ "Polling interval"
      assert html =~ "SQS Queue URL"
    end

    test "expanded Brevo: a note where a settings component would be" do
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, opened} =
        Panel.handle_event("toggle_expand", %{"provider" => "brevo_api"}, socket)

      html = render_panel(opened.assigns.expanded)

      assert html =~ "no settings of its own"
      assert html =~ "Polling interval"
      refute html =~ "Per-account event tracking"
    end
  end

  describe "the SQS tuning knobs in their new home" do
    test "max messages per poll saves from the expanded row" do
      assert {:noreply, socket} =
               SesSection.handle_event(
                 "update_max_messages",
                 %{"max_messages" => "7"},
                 bare_socket()
               )

      assert Emails.get_config().sqs_max_messages_per_poll == 7
      assert socket.assigns.flash["error"] == nil
    end

    test "visibility timeout saves from the expanded row" do
      assert {:noreply, socket} =
               SesSection.handle_event(
                 "update_visibility_timeout",
                 %{"timeout" => "600"},
                 bare_socket()
               )

      assert Emails.get_config().sqs_visibility_timeout == 600
      assert socket.assigns.flash["error"] == nil
    end
  end

  describe "one switch owns both SES event settings" do
    test "turning tracking on also turns on the ses-events precondition" do
      create_ses_profile()
      {:ok, _} = Emails.set_ses_events(false)
      {:ok, socket} = Panel.update(%{id: "panel"}, bare_socket())

      {:noreply, _socket} =
        Panel.handle_event("toggle_tracking", %{"provider" => "aws_ses"}, socket)

      # Both halves of `should_poll?/0` are on — the old UI let an operator
      # enable one and silently collect nothing.
      assert Emails.sqs_polling_enabled?()
      assert Emails.ses_events_enabled?()
    end
  end

  # `value || ""` covered a missing value but not an integer from a crafted
  # event, which Integer.parse/1 raised on just the same.
  describe "handle_event(\"update_interval\", ...) payload shapes" do
    test "accepts an integer" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => 7_000},
                 bare_socket()
               )

      assert Emails.get_sqs_config().polling_interval_ms == 7_000
      assert socket.assigns.flash["error"] == nil
    end

    test "rejects a missing value with a flash" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "value" => nil},
                 bare_socket()
               )

      assert socket.assigns.flash["error"]
    end
  end

  # The handler parses without bounds and leaves the range to the tracker
  # (SQSPollingManager: >= 1000 ms), so the edge is the tracker's.
  describe "handle_event(\"update_interval\", ...) range" do
    test "saves 1000, the tracker's minimum" do
      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "1000"},
                 bare_socket()
               )

      assert socket.assigns.flash["error"] == nil
      assert Emails.get_sqs_config().polling_interval_ms == 1_000
    end

    test "refuses 999, just below it" do
      {:noreply, _} =
        Panel.handle_event(
          "update_interval",
          %{"provider" => "aws_ses", "interval" => "5000"},
          bare_socket()
        )

      assert {:noreply, socket} =
               Panel.handle_event(
                 "update_interval",
                 %{"provider" => "aws_ses", "interval" => "999"},
                 bare_socket()
               )

      assert socket.assigns.flash["error"]
      assert Emails.get_sqs_config().polling_interval_ms == 5_000
    end
  end
end
