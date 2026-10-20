if Code.ensure_loaded?(PhoenixKit.API.Tool) do
  defmodule PhoenixKit.Modules.Emails.Verification.RunnerApi do
    @moduledoc """
    The two API tools a remote SMTP runner uses (see `docs/smtp-runner.md`), declared through
    `Emails.api_tools/0` for core's machine API (`POST /api/admin/v1/<tool>`, a bearer
    key with the scope `emails.smtp_runner:run`, whose owner holds the `emails`
    permission). Core checks the key, the scope, the owner's rights, the rate limit and
    the input schema; the handlers here only talk to `Verification.SmtpQueue` and
    `Verification.Runners`.

    This module exists only where core has `PhoenixKit.API.Tool` (2.63.0 and later);
    `Emails.api_tools/0` also checks that the key store is there, and declares nothing
    otherwise.

    ## `emails.claim_smtp_jobs`

    The runner's heartbeat and its source of work. Input: `max_sessions` (0 to 20, the
    free slots; 0 is a plain heartbeat) and `runner` (`version`, `os`, `name`,
    `port25`, `helo_auto`: what the runner says about itself). Answer:

        %{"sessions" => [%{"lease", "domain", "mx", "probe", "rcpt" => [%{"id", "email"}]}],
          "seen_ip" => "203.0.113.50",
          "settings" => %{"mail_from" => "verify@acme-mail.test" | nil, "helo" => nil,
                          "connect_timeout_s", "read_timeout_s", "max_report",
                          "idle_poll_s", "selftest_host"},
          "paused" => nil | %{"reason", "until"},
          "min_version" => "1.0.0"}

    `min_version` is the protocol version of the runner script
    (`Verification.Runners.runner_protocol_version/0`), not the version of this package.

    `settings.mail_from` is `nil` when the site has no usable sender (the runner must
    not open a session), `helo` is `nil` for "work it out from your IP". Unless the mode
    is `runner`, `sessions` is empty and `paused.reason` is `"mode_off"` (the heartbeat
    is recorded all the same).

    ## `emails.report_smtp_results`

    The raw facts of finished sessions (`results`, at most `max_report` per call, see
    `max_report/0`): see `Verification.SmtpQueue.report/4`. Answer:
    `%{"accepted", "ignored", "rejected", "settled", "paused"}`.

    Neither tool asks for a human's confirmation: `max_report` is kept within the
    limit above which core asks (`api_confirm_batch_over`), and a call that carries no
    list is never a batch.
    """

    alias PhoenixKit.API.FlowConfig
    alias PhoenixKit.API.Tool
    alias PhoenixKit.Modules.Emails.Verification.Config
    alias PhoenixKit.Modules.Emails.Verification.Runners
    alias PhoenixKit.Modules.Emails.Verification.SmtpQueue

    @scope Runners.scope()
    @max_report 50
    @outcomes ~w(answered connect_failed timeout reset)

    @doc "The scope a key needs to call the runner tools."
    @spec scope() :: String.t()
    def scope, do: @scope

    @doc """
    The most results one report may carry: 50, or core's `api_confirm_batch_over` when
    that is lower. The server sends it in every claim answer.
    """
    @spec max_report() :: pos_integer()
    def max_report, do: min(@max_report, FlowConfig.confirm_batch_over())

    @doc "The tools, for `Emails.api_tools/0`."
    @spec tools() :: [Tool.t()]
    def tools do
      [
        Tool.new!(
          [
            name: "emails.claim_smtp_jobs",
            audience: :admin,
            scope: @scope,
            permission: "emails",
            title: "Claim SMTP verification jobs",
            description:
              "The heartbeat of an SMTP runner, and its source of work. Leases up to max_sessions " <>
                "SMTP sessions (one domain each, a few addresses) for the runner to probe, and " <>
                "returns the settings it needs: MAIL FROM (null: do not start a session), HELO, " <>
                "timeouts, the largest report. An empty list of sessions is the normal answer " <>
                "when idle. Not a replayable call: a repeat leases again.",
            input_schema: claim_schema(),
            handler: {__MODULE__, :claim}
          ] ++ no_replay()
        ),
        Tool.new!(
          [
            name: "emails.report_smtp_results",
            audience: :admin,
            scope: @scope,
            permission: "emails",
            title: "Report SMTP session results",
            description:
              "Reports the raw facts of finished SMTP sessions (reply codes and texts, how the " <>
                "connection ended) for leases taken with emails.claim_smtp_jobs. The server " <>
                "classifies them. A report for a lease that is not the caller's, or that is no " <>
                "longer held, is ignored, so repeating a report is safe.",
            input_schema: report_schema(),
            handler: {__MODULE__, :report},
            annotations: %{idempotent: true},
            max_items: max_report()
          ] ++ no_replay()
        )
      ]
    end

    # `replay: false` exists from the core release after 2.63.0; the check is the one
    # core documents for a module that has to run on both.
    defp no_replay do
      if Code.ensure_loaded?(PhoenixKit.API.ControlFields) and
           function_exported?(PhoenixKit.API.ControlFields, :replay_tool?, 1),
         do: [replay: false],
         else: []
    end

    ## --- Handlers ---

    @doc false
    def claim(input, ctx) do
      if ctx.dry_run?, do: claim_preview(), else: do_claim(input, ctx)
    end

    defp do_claim(input, ctx) do
      runner = Runners.heartbeat(ctx.actor, runner_info(input["runner"]))
      now = PhoenixKit.Utils.Date.utc_now()

      {sessions, paused} =
        case Config.smtp_mode() do
          "runner" -> lease(runner, Map.get(input, "max_sessions", 1), now)
          other -> {[], mode_off(other)}
        end

      {:ok,
       %{
         "sessions" => Enum.map(sessions, &session_json/1),
         "seen_ip" => ctx.actor.ip,
         "settings" => settings(),
         "paused" => paused,
         "min_version" => Runners.runner_protocol_version()
       }}
    end

    # Not `runner`: nothing is leased, and work queued while the mode was on is
    # settled instead of waiting for a runner that is not wanted. In `local` mode the
    # queue is the server's own business.
    defp mode_off(mode) do
      if mode == "off", do: SmtpQueue.drain_disabled()
      %{"reason" => "mode_off", "until" => nil}
    end

    defp lease(runner, max_sessions, now) do
      case SmtpQueue.claim(runner, max_sessions, now) do
        {:ok, sessions} -> {sessions, nil}
        {:paused, _reason} -> {[], pause_json(runner, now)}
      end
    end

    defp pause_json(runner, now) do
      case Runners.pause_of(runner, now) do
        %{reason: reason, until: until} ->
          %{"reason" => reason || "paused", "until" => DateTime.to_iso8601(until)}

        nil ->
          %{"reason" => "paused", "until" => nil}
      end
    end

    defp session_json(session) do
      %{
        "lease" => session.lease,
        "domain" => session.domain,
        "mx" => session.mx,
        "probe" => session.probe,
        "rcpt" => Enum.map(session.rcpt, &%{"id" => &1.id, "email" => &1.email})
      }
    end

    defp settings do
      {mail_from, _source} = Config.smtp_mail_from()

      %{
        "mail_from" => mail_from,
        "helo" => Config.smtp_helo(),
        "connect_timeout_s" => Config.smtp_connect_timeout_s(),
        "read_timeout_s" => Config.smtp_read_timeout_s(),
        "max_report" => max_report(),
        "idle_poll_s" => Config.idle_poll_s(),
        "selftest_host" => Runners.selftest_host()
      }
    end

    # `helo_auto` is passed on only when the runner sent the key, so that an explicit null
    # (the runner found no EHLO name worth using) clears what was stored.
    defp runner_info(info) when is_map(info) do
      base = %{
        name: info["name"],
        version: info["version"],
        os: info["os"],
        port25: info["port25"]
      }

      if Map.has_key?(info, "helo_auto"),
        do: Map.put(base, :helo_auto, info["helo_auto"]),
        else: base
    end

    defp runner_info(_info), do: %{}

    defp claim_preview do
      counts = SmtpQueue.counts()
      {:preview, %{"queued" => counts.queued, "leased" => counts.leased}, fingerprint(counts)}
    end

    @doc false
    def report(input, ctx) do
      results = Map.get(input, "results", [])

      if ctx.dry_run? do
        {:preview, %{"results" => length(results)}, fingerprint(length(results))}
      else
        runner = Runners.heartbeat(ctx.actor, %{})
        now = PhoenixKit.Utils.Date.utc_now()
        {:ok, summary} = SmtpQueue.report(runner, results, now)
        paused = Runners.pause_of(Runners.reload(runner), now)

        {:ok,
         %{
           "accepted" => summary.accepted,
           "ignored" => summary.ignored,
           "rejected" => summary.rejected,
           "settled" => summary.settled,
           "paused" =>
             paused && %{"reason" => paused.reason, "until" => DateTime.to_iso8601(paused.until)}
         }}
      end
    end

    # What a dry run would touch, as a short fingerprint.
    defp fingerprint(term) do
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(term))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)
    end

    ## --- Schemas (static: core remembers the check per distinct schema) ---

    defp claim_schema do
      %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "max_sessions" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => SmtpQueue.max_sessions(),
            "description" => "Free session slots of the runner; 0 only sends the heartbeat."
          },
          "runner" => %{
            "type" => "object",
            "additionalProperties" => false,
            "description" => "What the runner says about itself.",
            "properties" => %{
              "version" => nullable_string(32),
              "os" => nullable_string(255),
              "name" => nullable_string(255),
              "helo_auto" => nullable_string(255),
              "port25" => %{"type" => "string", "enum" => ["open", "blocked", "unknown"]}
            }
          }
        }
      }
    end

    defp report_schema do
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["results"],
        "properties" => %{
          "results" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => @max_report,
            "description" =>
              "One entry per finished session; at most max_report of the claim answer " <>
                "(never more than #{@max_report}).",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["lease", "outcome"],
              "properties" => %{
                "lease" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
                "mx_used" => nullable_string(255),
                "outcome" => %{"type" => "string", "enum" => @outcomes},
                "steps" => %{
                  "type" => "array",
                  "maxItems" => 16,
                  "items" => reply_schema("cmd", 32)
                },
                "rcpt" => %{
                  "type" => "array",
                  "maxItems" => 100,
                  "items" => reply_schema("id", 64)
                },
                "ms" => %{"type" => "integer", "minimum" => 0}
              }
            }
          }
        }
      }
    end

    # `{key, code, text}`: a step of the dialogue or the reply to one RCPT.
    defp reply_schema(key, key_length) do
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => [key, "code"],
        "properties" => %{
          key => %{"type" => "string", "minLength" => 1, "maxLength" => key_length},
          "code" => %{"type" => "integer", "minimum" => 0, "maximum" => 999},
          "text" => %{"type" => ["string", "null"]}
        }
      }
    end

    defp nullable_string(max), do: %{"type" => ["string", "null"], "maxLength" => max}
  end
end
