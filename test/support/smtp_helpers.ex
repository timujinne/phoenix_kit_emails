defmodule PhoenixKitEmails.Test.SmtpHelpers do
  @moduledoc """
  Fixtures for the tests of the SMTP queue and the runner API: settings, queued
  addresses, a runner, and the JSON-shaped reports a runner would send. Nothing here
  opens a socket; the mail host's answers are plain data.
  """

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.FakeResolver
  alias PhoenixKitEmails.Test.Repo

  @doc "Sets a setting of the e-mail system."
  def put(key, value), do: Settings.update_setting_with_module(key, value, "email_system")

  @doc "Runner mode with a usable MAIL FROM, as a configured site has."
  def configure_runner_mode do
    put("email_verify_smtp_mode", "runner")
    put("from_email", "mail@acme-mail.test")
  end

  @doc "A domain name no other test uses (rows of async tests are isolated, advisory locks are not)."
  def unique_domain(prefix \\ "d"), do: "#{prefix}#{System.unique_integer([:positive])}.ee"

  @doc """
  Scripts the fake resolver for `domain` and queues `emails` (all at that domain)
  the way a batch job does. Returns the stored results.
  """
  def queue(domain, locals) when is_list(locals) do
    FakeResolver.put(domain,
      mx: {:ok, [%{host: "mx1." <> domain, pref: 10}, %{host: "mx2." <> domain, pref: 20}]}
    )

    for local <- locals do
      {:ok, result} = Verification.verify(local <> "@" <> domain, smtp: :enqueue)
      result
    end
  end

  @doc "The args of the `VerifyEmailWorker` job for the item of `email` in the batch."
  def verify_args(batch_uuid, email) do
    item = Repo.get_by!(BatchItem, batch_uuid: batch_uuid, email: email)
    %{"batch_uuid" => batch_uuid, "item_uuid" => item.uuid}
  end

  @doc "A connected runner (its heartbeat has been recorded)."
  def runner(opts \\ []) do
    actor = %{key_uuid: Keyword.get(opts, :key_uuid, Ecto.UUID.generate()), ip: "203.0.113.7"}
    Runners.heartbeat(actor, %{name: "TESTBOX", version: "1.0.0", port25: "open"})
  end

  @doc """
  The report of a session as a runner sends it (string keys). `rcpt` maps a row id or
  an index of the session's `rcpt` list to `{code, text}`.
  """
  def report(session, rcpt_replies, opts \\ []) do
    steps =
      Keyword.get(opts, :steps, [
        %{"cmd" => "banner", "code" => 220, "text" => "mx ESMTP"},
        %{"cmd" => "ehlo", "code" => 250, "text" => "mx"},
        %{"cmd" => "mail", "code" => 250, "text" => "2.1.0 Ok"}
      ])

    steps =
      case Keyword.get(opts, :probe) do
        nil -> steps
        {code, text} -> steps ++ [%{"cmd" => "rcpt_probe", "code" => code, "text" => text}]
      end

    %{
      "lease" => session.lease,
      "mx_used" => hd(session.mx),
      "outcome" => Keyword.get(opts, :outcome, "answered"),
      "steps" => steps,
      "rcpt" => rcpt_entries(session, rcpt_replies),
      "ms" => 120
    }
  end

  defp rcpt_entries(session, replies) do
    for {rcpt, index} <- Enum.with_index(session.rcpt),
        reply = Map.get(replies, rcpt.id) || Map.get(replies, index) do
      %{"id" => rcpt.id, "code" => elem(reply, 0), "text" => elem(reply, 1)}
    end
  end

  @doc "A report of a session that never connected."
  def failed_report(session, outcome \\ "connect_failed") do
    %{"lease" => session.lease, "outcome" => outcome, "steps" => [], "rcpt" => [], "ms" => 3}
  end
end
