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
    test "a full first page triggers a second fetch at the next offset" do
      create_brevo_profile()

      Application.put_env(:phoenix_kit_emails, :brevo_page_limit, 2)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :brevo_page_limit) end)

      message_id_1 = "<page1-a-#{System.unique_integer([:positive])}@example.com>"
      message_id_2 = "<page1-b-#{System.unique_integer([:positive])}@example.com>"
      message_id_3 = "<page2-a-#{System.unique_integer([:positive])}@example.com>"

      log1 = create_sent_log(message_id_1)
      log2 = create_sent_log(message_id_2)
      log3 = create_sent_log(message_id_3)

      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:fetch, query["offset"]})

        case query["offset"] do
          "0" ->
            Req.Test.json(conn, %{
              "events" => [
                brevo_event(%{"messageId" => message_id_1}),
                brevo_event(%{"messageId" => message_id_2})
              ]
            })

          "2" ->
            Req.Test.json(conn, %{
              "events" => [brevo_event(%{"messageId" => message_id_3})]
            })
        end
      end)

      assert :ok = BrevoPollingJob.perform(%Oban.Job{})

      assert_received {:fetch, "0"}
      assert_received {:fetch, "2"}

      assert Repo.get(Log, log1.uuid).status == "delivered"
      assert Repo.get(Log, log2.uuid).status == "delivered"
      assert Repo.get(Log, log3.uuid).status == "delivered"
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
