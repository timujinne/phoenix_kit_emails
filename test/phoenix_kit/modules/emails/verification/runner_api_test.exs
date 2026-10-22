defmodule PhoenixKit.Modules.Emails.Verification.RunnerApiTest do
  @moduledoc """
  The runner tools through core's real machine API: a real key made with
  `Keys.create_key/3`, the REST plug, the executor (scope, owner's rights, rate limit,
  schema, size limit), the handlers and the queue behind them. No sockets: the mail
  host's answers are the data of a report.
  """

  # Not async: the API processes and the module registry are named.
  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query
  import PhoenixKitEmails.Test.ApiHarness

  import PhoenixKitEmails.Test.SmtpHelpers,
    only: [queue: 2, unique_domain: 0, report: 2, report: 3]

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Cache, as: KeyCache
  alias PhoenixKit.API.Keys.Key, as: ApiKey
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.RunnerApi
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKit.Users.Permissions
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @claim "emails.claim_smtp_jobs"
  @report "emails.report_smtp_results"

  setup do
    setup_api()
    put_setting("email_verify_smtp_mode", "runner")
    put_setting("from_email", "mail@acme-mail.test")
    FakeResolver.put("acme-mail.test", mx: {:ok, [%{host: "mx.acme-mail.test", pref: 10}]})

    {owner, role} = user_with(["emails"])
    {key, token} = issue_key(owner)
    %{owner: owner, role: role, key: key, token: token}
  end

  defp claim(token, body \\ %{"max_sessions" => 4}, opts \\ []) do
    conn = request(token, @claim, body, opts)
    {conn.status, json(conn)}
  end

  defp report_results(token, results, opts \\ []) do
    conn = request(token, @report, %{"results" => results}, opts)
    {conn.status, json(conn)}
  end

  defp session_from(body, index \\ 0) do
    raw = Enum.at(body["sessions"], index)

    %{
      lease: raw["lease"],
      mx: raw["mx"],
      rcpt: Enum.map(raw["rcpt"], &%{id: &1["id"], email: &1["email"]})
    }
  end

  describe "the declared tools" do
    test "two admin tools with the runner scope and the emails permission" do
      tools = Map.new(Emails.api_tools(), &{&1.name, &1})
      assert Map.keys(tools) |> Enum.sort() == [@claim, @report]

      for tool <- Map.values(tools) do
        assert tool.audience == :admin
        assert tool.scope == "emails.smtp_runner:run"
        assert tool.permission == "emails"
        assert tool.input_schema["additionalProperties"] == false
        assert {:ok, _} = Tool.validate(tool)
      end

      assert tools[@report].annotations.idempotent
      assert tools[@report].max_items == 50
    end

    test "the nested objects are strict too" do
      [claim, report] = Emails.api_tools()
      assert claim.input_schema["properties"]["runner"]["additionalProperties"] == false
      items = report.input_schema["properties"]["results"]["items"]
      assert items["additionalProperties"] == false
      assert items["properties"]["steps"]["items"]["additionalProperties"] == false
      assert items["properties"]["rcpt"]["items"]["additionalProperties"] == false
    end

    test "replay is switched off where the core knows the field" do
      for tool <- Emails.api_tools(), Map.has_key?(Map.from_struct(tool), :replay) do
        assert tool.replay == false
      end
    end

    test "the discovery list shows them to a key that holds the scope, with their schemas", %{
      token: token
    } do
      conn = list_tools(token)
      assert conn.status == 200

      tools = Map.new(json(conn)["tools"], &{&1["name"], &1})
      assert Map.has_key?(tools, @claim) and Map.has_key?(tools, @report)
      assert tools[@claim]["scope"] == "emails.smtp_runner:run"
      assert tools[@report]["input_schema"]["properties"]["results"]["maxItems"] == 50
    end

    test "the schema allows as many sessions as the queue hands out", %{token: token} do
      claim = json(list_tools(token))["tools"] |> Enum.find(&(&1["name"] == @claim))

      assert claim["input_schema"]["properties"]["max_sessions"]["maximum"] ==
               SmtpQueue.max_sessions()
    end

    test "and hides them from a key without it", %{owner: owner} do
      {_key, token} = issue_key(owner, [])
      names = Enum.map(json(list_tools(token))["tools"], & &1["name"])
      refute @claim in names
      refute @report in names
    end

    test "max_report follows core's confirmation limit when that is lower" do
      assert RunnerApi.max_report() == 50

      put_setting("api_confirm_batch_over", "10")
      assert RunnerApi.max_report() == 10
      assert hd(tl(Emails.api_tools())).max_items == 10

      put_setting("api_confirm_batch_over", "500")
      assert RunnerApi.max_report() == 50
    end

    test "on a core without the machine API nothing is declared and runner mode is off" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      assert Emails.api_tools() == []
      assert Config.smtp_mode() == "off"
      assert Config.smtp_mode_setting() == "runner"
      refute Config.smtp_enabled?()
    end
  end

  describe "emails.claim_smtp_jobs" do
    test "answers sessions, the caller's address and the settings", %{token: token} do
      domain = unique_domain()
      queue(domain, ~w(info sales))

      assert {200, body} =
               claim(
                 token,
                 %{
                   "max_sessions" => 4,
                   "runner" => %{
                     "name" => "WORKSTATION",
                     "version" => "1.0.0",
                     "os" => "Windows 10",
                     "port25" => "open",
                     "helo_auto" => "host-203-0-113-50.example.net"
                   }
                 },
                 ip: "203.0.113.50"
               )

      assert [
               %{
                 "lease" => lease,
                 "domain" => ^domain,
                 "mx" => mx,
                 "probe" => probe,
                 "rcpt" => rcpt
               }
             ] = body["sessions"]

      assert is_binary(lease) and mx == ["mx1." <> domain, "mx2." <> domain]
      assert probe =~ ~r/\Ax[a-z2-7]{9}@#{Regex.escape(domain)}\z/

      assert Enum.map(rcpt, & &1["email"]) |> Enum.sort() == [
               "info@" <> domain,
               "sales@" <> domain
             ]

      assert Enum.all?(rcpt, &is_binary(&1["id"]))

      assert body["seen_ip"] == "203.0.113.50"
      assert body["paused"] == nil
      assert body["min_version"] == Runners.runner_protocol_version()
      assert body["min_version"] == "1.0.0"

      assert body["settings"] == %{
               "mail_from" => "mail@acme-mail.test",
               "helo" => nil,
               "connect_timeout_s" => 20,
               "read_timeout_s" => 30,
               "max_report" => 50,
               "idle_poll_s" => 30,
               "selftest_host" => "mx.acme-mail.test"
             }
    end

    test "every claim is the runner's heartbeat", %{token: token, key: key} do
      assert {200, %{"sessions" => []}} =
               claim(
                 token,
                 %{
                   "max_sessions" => 0,
                   "runner" => %{
                     "name" => "WORKSTATION",
                     "version" => "1.0.0",
                     "os" => "Windows",
                     "port25" => "blocked",
                     "helo_auto" => "host.example.ee"
                   }
                 },
                 ip: "203.0.113.51"
               )

      runner = Repo.get_by!(Runner, api_key_uuid: key.uuid)
      assert runner.name == "WORKSTATION"
      assert runner.version == "1.0.0"
      assert runner.os == "Windows"
      assert runner.port25 == "blocked"
      assert runner.port25_checked_at
      assert runner.helo_auto == "host.example.ee"
      assert runner.public_ip == "203.0.113.51"
      assert DateTime.diff(DateTime.utc_now(), runner.last_seen_at) < 5

      # A second claim, without the details, keeps what it knows.
      assert {200, _} = claim(token, %{})
      assert Repo.aggregate(Runner, :count) == 1
      assert Repo.get_by!(Runner, api_key_uuid: key.uuid).name == "WORKSTATION"
    end

    test "a claim with helo_auto null clears the stored name, one without keeps it", %{
      token: token,
      key: key
    } do
      assert {200, _} = claim(token, %{"runner" => %{"helo_auto" => "localhost"}})
      assert {200, _} = claim(token, %{"runner" => %{"name" => "BOX"}})
      assert Repo.get_by!(Runner, api_key_uuid: key.uuid).helo_auto == "localhost"

      assert {200, _} = claim(token, %{"runner" => %{"helo_auto" => nil}})
      runner = Repo.get_by!(Runner, api_key_uuid: key.uuid)
      assert runner.helo_auto == nil
      assert runner.name == "BOX"
    end

    test "max_sessions defaults to one", %{token: token} do
      for _ <- 1..2, do: queue(unique_domain(), ~w(a))
      assert {200, %{"sessions" => [_]}} = claim(token, %{})
    end

    test "a session is leased once: the next claim finds the domain held", %{token: token} do
      queue(unique_domain(), ~w(a))
      assert {200, %{"sessions" => [_]}} = claim(token)
      assert {200, %{"sessions" => []}} = claim(token)
    end

    test "with the mode off: no sessions, mode_off, and the heartbeat is still recorded", %{
      token: token,
      key: key
    } do
      put_setting("email_verify_smtp_mode", "off")

      assert {200, body} = claim(token, %{"max_sessions" => 4, "runner" => %{"name" => "BOX"}})
      assert body["sessions"] == []
      assert body["paused"] == %{"reason" => "mode_off", "until" => nil}
      assert Repo.get_by!(Runner, api_key_uuid: key.uuid).name == "BOX"
    end

    test "in local mode a remote runner is told the mode is off for it", %{token: token} do
      put_setting("email_verify_smtp_mode", "local")
      assert {200, %{"sessions" => [], "paused" => %{"reason" => "mode_off"}}} = claim(token)
    end

    test "without a usable MAIL FROM there are no sessions, and the settings say so", %{
      token: token
    } do
      put_setting("from_email", "noreply@localhost")
      queue(unique_domain(), ~w(a))

      assert {200, body} = claim(token)
      assert body["sessions"] == []
      assert body["settings"]["mail_from"] == nil
      assert body["paused"] == nil
      assert Repo.aggregate(from(i in Item, where: i.state == "queued"), :count) == 1
    end

    test "the override and the helo are handed to the runner", %{token: token} do
      put_setting("email_verify_smtp_mail_from", "verify@acme-mail.test")
      put_setting("email_verify_smtp_helo", "mail.acme-mail.test")
      put_setting("email_verify_smtp_selftest_host", "mx9.acme-mail.test")

      assert {200, %{"settings" => settings}} = claim(token)
      assert settings["mail_from"] == "verify@acme-mail.test"
      assert settings["helo"] == "mail.acme-mail.test"
      assert settings["selftest_host"] == "mx9.acme-mail.test"
    end

    test "a helo that is not a plain host name is not handed to the runner", %{token: token} do
      put_setting("email_verify_smtp_helo", "mx.example.ee\r\nDATA")

      assert {200, %{"settings" => settings}} = claim(token)
      assert settings["helo"] == nil
    end

    test "with the mode off a claim settles what is still queued", %{token: token} do
      domain = unique_domain()
      queue(domain, ~w(a))
      put_setting("email_verify_smtp_mode", "off")

      assert {200, body} = claim(token)
      assert body["sessions"] == []
      assert body["paused"] == %{"reason" => "mode_off", "until" => nil}

      assert Repo.aggregate(from(i in Item, where: i.state == "done"), :count) == 1
      assert %Result{reason: "smtp_disabled"} = Repo.get_by!(Result, email: "a@" <> domain)
    end

    test "a paused runner is told why, with nothing leased", %{token: token, key: key} do
      queue(unique_domain(), ~w(a))
      assert {200, _} = claim(token, %{"max_sessions" => 0})
      until = DateTime.add(DateTime.utc_now(), 600) |> DateTime.truncate(:second)

      Repo.update_all(from(r in Runner, where: r.api_key_uuid == ^key.uuid),
        set: [paused_until: until, pause_reason: "port 25 closed"]
      )

      assert {200, body} = claim(token)
      assert body["sessions"] == []

      assert body["paused"] == %{
               "reason" => "port 25 closed",
               "until" => DateTime.to_iso8601(until)
             }
    end

    test "max_sessions above the limit and unknown fields are refused", %{token: token} do
      assert {422, %{"code" => "validation_failed"}} = claim(token, %{"max_sessions" => 21})
      assert {422, _} = claim(token, %{"max_sessions" => -1})
      assert {422, _} = claim(token, %{"max_sessions" => "4"})
      assert {422, _} = claim(token, %{"surprise" => true})
      assert {422, _} = claim(token, %{"runner" => %{"colour" => "red"}})
      assert {422, _} = claim(token, %{"runner" => %{"port25" => "maybe"}})
    end

    test "a dry run leases nothing", %{token: token} do
      queue(unique_domain(), ~w(a))

      assert {200, %{"executed" => false, "dry_run" => true, "preview" => %{"queued" => 1}}} =
               claim(token, %{"max_sessions" => 4, "dry_run" => true})

      assert Repo.aggregate(from(i in Item, where: i.state == "leased"), :count) == 0
    end
  end

  describe "emails.report_smtp_results" do
    test "settles the session: the verdict is stored, the runner credited", %{
      token: token,
      key: key
    } do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      session = session_from(body)

      result = report(session, %{0 => {250, "2.1.5 Ok"}}, probe: {550, "5.1.1 no such user"})

      assert {200,
              %{"accepted" => 1, "ignored" => 0, "rejected" => 0, "settled" => 1, "paused" => nil}} =
               report_results(token, [result])

      assert %Result{status: "valid", reason: "smtp_ok", level: "smtp"} =
               Repo.get_by!(Result, email: "info@" <> domain)

      assert Repo.get_by!(Runner, api_key_uuid: key.uuid).jobs_done == 1
    end

    test "a repeated report is ignored", %{token: token} do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      result = report(session_from(body), %{0 => {550, "5.1.1 user unknown"}}, probe: {550, "x"})

      assert {200, %{"accepted" => 1}} = report_results(token, [result])
      assert {200, %{"accepted" => 0, "ignored" => 1}} = report_results(token, [result])
    end

    test "another key's lease is ignored", %{token: token, owner: owner} do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      result = report(session_from(body), %{0 => {250, "ok"}})

      {_other_key, other_token} = issue_key(owner)
      assert {200, %{"accepted" => 0, "ignored" => 1}} = report_results(other_token, [result])
      assert Repo.get_by!(Result, email: "info@" <> domain).reason == "smtp_pending"
    end

    test "up to max_report results need no confirmation, one more is refused", %{token: token} do
      lease = fn n -> %{"lease" => "none-#{n}", "outcome" => "timeout"} end

      assert {200, %{"ignored" => 50}} = report_results(token, Enum.map(1..50, lease))

      assert {422, %{"code" => "validation_failed", "context" => %{"errors" => [error | _]}}} =
               report_results(token, Enum.map(1..51, lease))

      assert error["limit"] == 50
    end

    test "max_report is lower when core's confirmation limit is lower; within it nothing is confirmed",
         %{token: token} do
      put_setting("api_confirm_batch_over", "5")
      assert {200, %{"settings" => %{"max_report" => 5}}} = claim(token)

      lease = fn n -> %{"lease" => "none-#{n}", "outcome" => "timeout"} end
      assert {200, %{"ignored" => 5} = body} = report_results(token, Enum.map(1..5, lease))
      refute Map.has_key?(body, "confirmation")
      assert {422, _} = report_results(token, Enum.map(1..6, lease))
    end

    test "results of the wrong shape never reach the queue", %{token: token} do
      assert {422, _} = report_results(token, [%{"lease" => "x", "outcome" => "exploded"}])
      assert {422, _} = report_results(token, [%{"outcome" => "answered"}])

      assert {422, _} =
               report_results(token, [%{"lease" => "x", "outcome" => "answered", "extra" => 1}])

      assert {422, _} =
               report_results(token, [
                 %{
                   "lease" => "x",
                   "outcome" => "answered",
                   "rcpt" => [%{"id" => "a", "code" => "250"}]
                 }
               ])

      assert {422, _} = report_results(token, [])
      assert {422, _} = report_results(token, "garbage")
    end

    test "long reply texts are accepted and cut by the server", %{token: token} do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      long = String.duplicate("x", 5_000)
      result = report(session_from(body), %{0 => {451, long}})

      assert {200, %{"accepted" => 1}} = report_results(token, [result])

      assert String.length(DomainCache.get(domain).grey_message) == 512
    end

    test "a report is accepted while the mode is off: settling is not the mode's business", %{
      token: token
    } do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      put_setting("email_verify_smtp_mode", "off")
      result = report(session_from(body), %{0 => {550, "5.1.1 user unknown"}}, probe: {550, "x"})

      assert {200, %{"accepted" => 1}} = report_results(token, [result])
    end

    test "a dry run settles nothing", %{token: token} do
      domain = unique_domain()
      queue(domain, ~w(info))
      {200, body} = claim(token)
      result = report(session_from(body), %{0 => {250, "ok"}})

      conn = request(token, @report, %{"results" => [result], "dry_run" => true})
      assert conn.status == 200
      assert %{"dry_run" => true, "preview" => %{"results" => 1}} = json(conn)
      assert Repo.get_by!(Result, email: "info@" <> domain).reason == "smtp_pending"
    end
  end

  describe "who may call" do
    test "no key: 401", _ do
      conn = request("pk_00000000_" <> String.duplicate("a", 43), @claim, %{})
      assert conn.status == 401
    end

    test "a key without the runner scope: 403, naming the scope", %{owner: owner} do
      {_key, token} = issue_key(owner, [])

      conn = request(token, @claim, %{})
      assert conn.status == 403

      assert %{
               "code" => "forbidden",
               "context" => %{"required_scope" => "emails.smtp_runner:run"}
             } = json(conn)

      conn = request(token, @report, %{"results" => [%{"lease" => "x", "outcome" => "timeout"}]})
      assert conn.status == 403
    end

    test "a revoked key: 401, and no runner row is written", %{
      owner: owner,
      key: key,
      token: token
    } do
      assert {200, _} = claim(token)
      assert {:ok, _} = Keys.revoke(key, owner.uuid)

      assert {401, _} = claim(token)
      conn = request(token, @report, %{"results" => [%{"lease" => "x", "outcome" => "timeout"}]})
      assert conn.status == 401
    end

    test "an expired key: 401", %{key: key, token: token} do
      assert {200, _} = claim(token)

      Repo.update_all(from(k in ApiKey, where: k.uuid == ^key.uuid),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
      )

      KeyCache.invalidate(key.prefix)
      assert {401, _} = claim(token)
    end

    test "an owner who lost the emails permission: the scope goes with it (403)", %{
      role: role,
      token: token
    } do
      assert {200, _} = claim(token)
      :ok = Permissions.revoke_permission(role.uuid, "emails")

      assert {403, %{"code" => "forbidden"}} = claim(token)
    end

    test "a deactivated owner: 401", %{owner: owner, token: token} do
      assert {200, _} = claim(token)
      owner |> Ecto.Changeset.change(is_active: false) |> Repo.update!()

      assert {401, _} = claim(token)
    end

    test "a key limited to an address refuses another", %{owner: owner} do
      {_key, token} =
        issue_key(owner, ["emails.smtp_runner:run"], %{allowed_ips: ["203.0.113.9"]})

      assert {403, %{"code" => "ip_not_allowed"}} = claim(token, %{}, ip: "203.0.113.10")
      assert {200, _} = claim(token, %{}, ip: "203.0.113.9")
    end

    test "the admin API switched off: 404", %{token: token} do
      put_setting("api_admin_enabled", "false")
      assert {404, _} = claim(token)
    end

    test "the emails module switched off: its tools are gone (module_disabled)", %{token: token} do
      put_setting("email_enabled", "false")
      assert {status, _} = claim(token)
      assert status in [403, 404]
    end

    test "a key cannot be made with the runner scope by an owner without the permission" do
      {owner, _} = user_with([])

      assert {:error, :invalid_scopes} =
               Keys.create_key(owner, scope_of(owner), %{
                 name: "x",
                 scopes: ["emails.smtp_runner:run"]
               })
    end
  end
end
