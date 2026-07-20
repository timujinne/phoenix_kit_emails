defmodule PhoenixKit.Modules.Emails.BrevoPollingJobTest do
  @moduledoc """
  `BrevoClient`'s HTTP layer is stubbed via `Req.Test` (see
  `config/test.exs`'s `:brevo_client_req_options` — never a real network
  call). `@page_limit` is shrunk to 2 via `:brevo_page_limit` app config
  in the pagination test so it doesn't need thousands of fixture events.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob
  alias PhoenixKit.Modules.Emails.Event
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKitEmails.Test.Repo

  @stub PhoenixKit.Modules.Emails.BrevoPollingJobTest.Stub

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual, queues: [], plugins: false})
    {:ok, _} = Emails.enable_system()
    {:ok, _} = Emails.set_brevo_events_enabled(true)
    :ok
  end

  defp create_brevo_profile(opts \\ []) do
    api_key = Keyword.get(opts, :api_key, "test-brevo-api-key")
    enabled = Keyword.get(opts, :enabled, true)

    {:ok, %{uuid: integration_uuid}} =
      Integrations.add_connection("brevo_api", "Brevo #{System.unique_integer([:positive])}")

    if api_key do
      {:ok, _} = Integrations.save_setup(integration_uuid, %{"api_key" => api_key})
    end

    {:ok, profile} =
      SendProfiles.create_send_profile(%{
        name: "Brevo profile #{System.unique_integer([:positive])}",
        integration_uuid: integration_uuid,
        provider_kind: "brevo_api",
        from_email: "sender@example.com",
        enabled: enabled
      })

    profile
  end

  defp create_sent_log(brevo_message_id) do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "brevo_api",
        status: "queued",
        aws_message_id: brevo_message_id
      })
      |> Repo.insert()

    log
  end

  defp brevo_event(overrides) do
    Map.merge(
      %{
        "date" => "2026-07-19T10:00:00Z",
        "email" => "recipient@example.com",
        "event" => "delivered",
        "messageId" => "<msg-#{System.unique_integer([:positive])}@example.com>"
      },
      overrides
    )
  end

  describe "sender-aware gate" do
    test "0 enabled Brevo profiles: perform/1 no-ops without ever touching HTTP" do
      # No Req.Test.stub/2 registered at all — if fetch_page/4 were reached,
      # BrevoClient.fetch_events/3 would raise "no mock or stub". Completing
      # without raising proves the gate short-circuited before any HTTP call.
      assert :ok = BrevoPollingJob.perform(%Oban.Job{})
    end

    test "a disabled Brevo profile doesn't count towards the gate either" do
      create_brevo_profile(enabled: false)
      assert :ok = BrevoPollingJob.perform(%Oban.Job{})
    end
  end

  describe "idempotency" do
    test "the same event fetched twice within one cycle produces one Event row, not two" do
      create_brevo_profile()
      message_id = "<idempotent-#{System.unique_integer([:positive])}@example.com>"
      log = create_sent_log(message_id)

      event = brevo_event(%{"messageId" => message_id})

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"events" => [event, event]})
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      events =
        Event
        |> where(email_log_uuid: ^log.uuid, event_type: "delivery")
        |> Repo.all()

      assert length(events) == 1
    end
  end

  describe "pagination" do
    test "a full first page triggers a second fetch at the next offset, then the day closes into today on a short page" do
      profile = create_brevo_profile()

      Application.put_env(:phoenix_kit_emails, :brevo_page_limit, 2)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :brevo_page_limit) end)

      message_id_1 = "<page1-a-#{System.unique_integer([:positive])}@example.com>"
      message_id_2 = "<page1-b-#{System.unique_integer([:positive])}@example.com>"
      message_id_3 = "<page2-a-#{System.unique_integer([:positive])}@example.com>"

      log1 = create_sent_log(message_id_1)
      log2 = create_sent_log(message_id_2)
      log3 = create_sent_log(message_id_3)

      today = Date.utc_today()
      yesterday_str = today |> Date.add(-1) |> Date.to_iso8601()
      today_str = Date.to_iso8601(today)
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:fetch, query["startDate"], query["offset"]})

        case {query["startDate"], query["offset"]} do
          {^yesterday_str, "0"} ->
            Req.Test.json(conn, %{
              "events" => [
                brevo_event(%{"messageId" => message_id_1}),
                brevo_event(%{"messageId" => message_id_2})
              ]
            })

          {^yesterday_str, "2"} ->
            Req.Test.json(conn, %{
              "events" => [brevo_event(%{"messageId" => message_id_3})]
            })

          {^today_str, "0"} ->
            Req.Test.json(conn, %{"events" => []})
        end
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert_received {:fetch, ^yesterday_str, "0"}
      assert_received {:fetch, ^yesterday_str, "2"}
      assert_received {:fetch, ^today_str, "0"}

      assert Repo.get(Log, log1.uuid).status == "delivered"
      assert Repo.get(Log, log2.uuid).status == "delivered"
      assert Repo.get(Log, log3.uuid).status == "delivered"

      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{date: today, offset: 0}
    end
  end

  describe "watermark cursor" do
    test "cold start begins at yesterday, offset 0 — the same floor the old unconditional window guaranteed" do
      profile = create_brevo_profile()
      refute Emails.get_brevo_watermark(profile.integration_uuid)

      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => []}) end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      # Yesterday's (empty) page was short, and yesterday < today, so the
      # walk immediately continued into today, which was also empty and
      # short — but today never auto-advances past itself.
      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{
               date: Date.utc_today(),
               offset: 0
             }
    end

    test "the watermark never leaves today, even when today's own page comes back short" do
      profile = create_brevo_profile()
      today = Date.utc_today()
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, today, 5)

      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => []}) end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{date: today, offset: 5}
    end

    test "several small backlog days close within a single cycle" do
      profile = create_brevo_profile()
      today = Date.utc_today()
      day_0 = Date.add(today, -4)
      day_1 = Date.add(today, -3)
      day_2 = Date.add(today, -2)
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, day_0, 0)

      backlog_days = MapSet.new([day_0, day_1, day_2], &Date.to_iso8601/1)
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:fetch, query["startDate"]})

        events =
          if MapSet.member?(backlog_days, query["startDate"]) do
            [brevo_event(%{"messageId" => "<#{query["startDate"]}@example.com>"})]
          else
            []
          end

        Req.Test.json(conn, %{"events" => events})
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      for day <- [day_0, day_1, day_2, Date.add(today, -1), today] do
        day_str = Date.to_iso8601(day)
        assert_received {:fetch, ^day_str}
      end

      # All 3 backlog days plus yesterday and today were walked in one
      # perform/1 call — the watermark ends the cycle caught up.
      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{date: today, offset: 0}
    end

    test "hitting the page cap mid-backlog leaves the watermark exactly where it stopped, not reset" do
      profile = create_brevo_profile()
      Application.put_env(:phoenix_kit_emails, :brevo_page_limit, 1)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :brevo_page_limit) end)

      today = Date.utc_today()
      day_0 = Date.add(today, -3)
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, day_0, 0)

      # Every single day, including today, has a "full" page (limit 1) —
      # nothing ever looks exhausted, so the cap (10 pages) is what stops
      # the cycle, at day_0 + 9 pages of offset advance (day_0 never
      # closes since it never sees a short page).
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"events" => [brevo_event(%{})]})
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{date: day_0, offset: 10}
    end
  end

  describe "trailing safety re-check" do
    test "catches a late-arriving event on a day the watermark already closed" do
      profile = create_brevo_profile()
      today = Date.utc_today()
      yesterday = Date.add(today, -1)

      # Simulates last cycle having already closed yesterday (short page)
      # and moved on to today, *before* Brevo finished indexing an event
      # that actually happened late yesterday (indexing lag) — or one
      # Brevo attributes to yesterday under a different day boundary than
      # this job's UTC `today()` (timezone ambiguity). Either way: without
      # the trailing re-check, nothing would ever query yesterday again.
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, today, 0)

      late_message_id = "<late-#{System.unique_integer([:positive])}@example.com>"
      log = create_sent_log(late_message_id)

      late_event =
        brevo_event(%{
          "messageId" => late_message_id,
          "date" => "#{Date.to_iso8601(yesterday)}T23:59:50Z"
        })

      yesterday_str = Date.to_iso8601(yesterday)
      today_str = Date.to_iso8601(today)

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)

        case query["startDate"] do
          ^yesterday_str -> Req.Test.json(conn, %{"events" => [late_event]})
          ^today_str -> Req.Test.json(conn, %{"events" => []})
        end
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert Repo.get(Log, log.uuid).status == "delivered"

      # The trailing re-check has no cursor of its own — the persisted
      # watermark is untouched by it, still exactly where the forward
      # walk (today, short page, stays put) left it.
      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{date: today, offset: 0}
    end

    test "does not run at all on cold start — the forward walk is about to fetch that same day itself" do
      profile = create_brevo_profile()
      refute Emails.get_brevo_watermark(profile.integration_uuid)

      today_str = Date.to_iso8601(Date.utc_today())
      yesterday_str = today_str |> Date.from_iso8601!() |> Date.add(-1) |> Date.to_iso8601()
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:fetch, query["startDate"], query["offset"]})
        Req.Test.json(conn, %{"events" => []})
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      # assert_received consumes one matching message each; if the
      # trailing re-check had (incorrectly) also fired on cold start,
      # there would be a second {:fetch, yesterday_str, "0"} left in the
      # mailbox for refute_received to catch below.
      assert_received {:fetch, ^yesterday_str, "0"}
      assert_received {:fetch, ^today_str, "0"}
      refute_received {:fetch, ^yesterday_str, "0"}
    end
  end

  describe "resilience to a mid-cycle failure" do
    test "a failed page fetch leaves the watermark exactly at the last successfully-processed page, not reset and not skipped ahead" do
      profile = create_brevo_profile()
      Application.put_env(:phoenix_kit_emails, :brevo_page_limit, 2)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :brevo_page_limit) end)

      message_id_1 = "<crash-a-#{System.unique_integer([:positive])}@example.com>"
      message_id_2 = "<crash-b-#{System.unique_integer([:positive])}@example.com>"
      log1 = create_sent_log(message_id_1)
      log2 = create_sent_log(message_id_2)

      yesterday_str = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)

        case {query["startDate"], query["offset"]} do
          {^yesterday_str, "0"} ->
            Req.Test.json(conn, %{
              "events" => [
                brevo_event(%{"messageId" => message_id_1}),
                brevo_event(%{"messageId" => message_id_2})
              ]
            })

          {^yesterday_str, "2"} ->
            Plug.Conn.send_resp(conn, 500, "simulated failure")
        end
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      # Page 1 was processed (and its effects are real, dedup-safe rows)
      # despite page 2 failing right after it.
      assert Repo.get(Log, log1.uuid).status == "delivered"
      assert Repo.get(Log, log2.uuid).status == "delivered"

      # The watermark reflects exactly "page 1 done, page 2 not yet" — a
      # retry next cycle re-fetches at most that one failed page, not the
      # whole day from 0.
      assert Emails.get_brevo_watermark(profile.integration_uuid) == %{
               date: Date.utc_today() |> Date.add(-1),
               offset: 2
             }
    end
  end

  describe "stale watermark cleanup" do
    test "a watermark for an integration that's no longer in the active set gets pruned" do
      profile = create_brevo_profile()
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, Date.utc_today(), 100)

      # Stands in for a deleted integration: a watermark whose uuid
      # doesn't correspond to any currently-active integration at all.
      ghost_uuid = Ecto.UUID.generate()
      {:ok, _} = Emails.set_brevo_watermark(ghost_uuid, Date.utc_today(), 50)

      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => []}) end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert Emails.get_brevo_watermark(profile.integration_uuid)
      refute Emails.get_brevo_watermark(ghost_uuid)
    end

    test "excluding an integration from polling prunes its watermark too" do
      profile = create_brevo_profile()
      {:ok, _} = Emails.set_brevo_watermark(profile.integration_uuid, Date.utc_today(), 100)
      {:ok, _} = Emails.set_brevo_polling_excluded_integrations([profile.integration_uuid])

      # Not stubbed — the excluded integration must never be fetched.
      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      refute Emails.get_brevo_watermark(profile.integration_uuid)
    end
  end

  describe "misconfiguration" do
    test "an integration with no api_key backs off instead of raising" do
      create_brevo_profile(api_key: nil)

      # Not stubbed — fetch_page/4 must never be reached for a
      # misconfigured integration (poll_integration/1 returns
      # :misconfigured before ever calling BrevoClient).
      assert :ok = BrevoPollingJob.perform(%Oban.Job{})
    end
  end

  describe "per-integration opt-out" do
    test "an excluded integration is never fetched, even though it's an active profile" do
      profile = create_brevo_profile()
      {:ok, _} = Emails.set_brevo_polling_excluded_integrations([profile.integration_uuid])

      # Not stubbed — if the excluded integration were still fetched,
      # BrevoClient.fetch_events/3 would raise "no mock or stub".
      assert :ok = BrevoPollingJob.perform(%Oban.Job{})
    end

    test "only the non-excluded integration is actually fetched" do
      _kept = create_brevo_profile(api_key: "kept-key")
      excluded = create_brevo_profile(api_key: "excluded-key")
      {:ok, _} = Emails.set_brevo_polling_excluded_integrations([excluded.integration_uuid])

      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "api-key")
        send(test_pid, {:fetched_with_key, api_key})
        Req.Test.json(conn, %{"events" => []})
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert_received {:fetched_with_key, "kept-key"}
      refute_received {:fetched_with_key, "excluded-key"}
    end
  end

  describe "forced (poll_now) runs" do
    test "a forced job still runs a cycle while brevo_events_enabled is off" do
      create_brevo_profile()
      {:ok, _} = Emails.set_brevo_events_enabled(false)

      message_id = "<forced-#{System.unique_integer([:positive])}@example.com>"
      log = create_sent_log(message_id)
      event = brevo_event(%{"messageId" => message_id})

      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"events" => [event]}) end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{args: %{"forced" => true}})

      assert Repo.get(Log, log.uuid).status == "delivered"
    end

    test "a forced job still no-ops when the system itself is disabled" do
      {:ok, _} = Emails.disable_system()

      # Not stubbed — the system-disabled check must short-circuit before
      # anything (including HTTP) is touched, forced or not.
      assert :ok = BrevoPollingJob.perform(%Oban.Job{args: %{"forced" => true}})
    end
  end

  describe "status observability" do
    test "last_polled_at is recorded even on a zero-profile no-op cycle" do
      refute Emails.get_brevo_last_polled_at()

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert Emails.get_brevo_last_polled_at()
    end
  end
end
