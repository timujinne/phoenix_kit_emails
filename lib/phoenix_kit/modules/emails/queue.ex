defmodule PhoenixKit.Modules.Emails.Queue do
  @moduledoc """
  Decides whether an outgoing message is sent inline or handed to Oban.

  Core calls `c:PhoenixKit.Email.Provider.maybe_enqueue/2` (an optional callback,
  implemented by `PhoenixKit.Modules.Emails.Provider`) right after interception, on **both**
  delivery paths. That placement is the whole point: the host application's own
  mail — password resets, confirmations, anything sent through its statically
  configured mailer — goes through the same gate as mail sent through this
  package, so "everything that leaves the app" is one queue and one log.

  ## What is queued

  Nothing, unless the email system itself is enabled (`email_enabled`) — a
  disabled system must not change how mail is sent, only stop recording it. On
  top of that:

    * `email_queue_enabled` (default **true**) is the master switch;
    * authentication mail (core tags it `campaign_id: "authentication"`) is sent
      inline unless `email_queue_auth_mail` is turned on. Queueing a password
      reset means the user waits for a worker to pick it up, and a stuck queue
      turns into "I never got the email" — the one case where the latency is
      worse than the throughput is worth;
    * a caller may always opt out per message with `queue: false`;
    * messages with attachments are sent inline. The job carries the message as
      JSON args, and attachment payloads have no business in the jobs table;
    * nothing is queued unless the host application actually declared the
      `:emails` Oban queue (`runnable?/0`) — see the warning in that function.

  Each of these is a `:continue`, i.e. "not mine, send it now" — never an error.
  A queue that swallows mail on a bad day is worse than one that never engages.

  ## Callers that pick their own transport must opt out

  The queue offer sits inside **both** of core's delivery paths, including
  `PhoenixKit.Mailer.deliver_via_integration/3` — but the opts core hands us do
  not carry the integration uuid that call was made with, only its `:provider`
  string. `SendJob` therefore re-sends through `deliver_email/2`, which resolves
  the *default* integration. For a send routed at an explicitly chosen
  connection (a newsletter send profile, a per-tenant relay) that is a silent
  change of transport, so such callers must pass `queue: false` until core
  carries the uuid into the job. Sends that were already going out through the
  default integration are unaffected — it is the same resolution either way.
  """

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SendJob
  alias PhoenixKit.Settings
  alias Swoosh.Email

  @auth_campaign "authentication"
  @log_header "X-PhoenixKit-Log-Id"

  @doc """
  Returns `{:queued, log_uuid}` when the message was handed to Oban, `:continue`
  when the caller should send it on this process.
  """
  @spec maybe_enqueue(Email.t(), keyword()) :: :continue | {:queued, String.t()}
  def maybe_enqueue(%Email{} = email, opts) do
    if queue?(email, opts) do
      enqueue(email, opts)
    else
      :continue
    end
  end

  def maybe_enqueue(_email, _opts), do: :continue

  @doc "Master switch — `email_queue_enabled`, defaults to true."
  @spec enabled? :: boolean()
  def enabled?, do: Settings.get_boolean_setting("email_queue_enabled", true)

  @doc """
  Whether the host application actually declared the `:emails` Oban queue.

  Load-bearing, not diagnostic: `Oban.insert/1` happily accepts a job for a queue
  nobody runs, so on a host that never added `emails: N` the message would be
  stored and never sent — the queue would look enabled and quietly swallow the
  mail. We therefore refuse to queue at all unless the host can drain it.

  Reads the parent app's compile-time Oban config, which is how PhoenixKit
  installs Oban. A host that declares queues as a map, or starts Oban at runtime
  with `Oban.start_link/1`, reads as "not runnable" here — that is the safe
  direction (inline send, never a stuck queue), not a mail outage.
  """
  @spec runnable? :: boolean()
  def runnable? do
    PhoenixKit.Config.get_parent_app()
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> then(fn
      queues when is_list(queues) -> Keyword.has_key?(queues, :emails)
      _ -> false
    end)
  rescue
    _ -> false
  end

  @doc "Whether authentication mail is queued too — `email_queue_auth_mail`, defaults to false."
  @spec auth_mail_enabled? :: boolean()
  def auth_mail_enabled?, do: Settings.get_boolean_setting("email_queue_auth_mail", false)

  @doc "Sets `email_queue_enabled`."
  @spec set_enabled(boolean()) :: {:ok, term()} | {:error, term()}
  def set_enabled(value) when is_boolean(value),
    do: Settings.update_boolean_setting_with_module("email_queue_enabled", value, "email_system")

  @doc "Sets `email_queue_auth_mail`."
  @spec set_auth_mail_enabled(boolean()) :: {:ok, term()} | {:error, term()}
  def set_auth_mail_enabled(value) when is_boolean(value),
    do:
      Settings.update_boolean_setting_with_module(
        "email_queue_auth_mail",
        value,
        "email_system"
      )

  @doc """
  Explains, in one atom, why the queue would not take the next message — for the
  settings page, which otherwise has to guess.

  `:ok` means it would.
  """
  @spec status :: :ok | :system_disabled | :queue_disabled | :no_oban_queue
  def status do
    cond do
      not Emails.enabled?() -> :system_disabled
      not enabled?() -> :queue_disabled
      not runnable?() -> :no_oban_queue
      true -> :ok
    end
  end

  # --- decision --------------------------------------------------------------

  defp queue?(email, opts) do
    Emails.enabled?() and enabled?() and runnable?() and
      Keyword.get(opts, :queue, true) != false and
      not auth_mail_excluded?(opts) and
      not has_attachments?(email)
  end

  defp auth_mail_excluded?(opts) do
    Keyword.get(opts, :campaign_id) == @auth_campaign and not auth_mail_enabled?()
  end

  defp has_attachments?(%Email{attachments: attachments}) when is_list(attachments),
    do: attachments != []

  defp has_attachments?(_email), do: false

  # --- enqueue ---------------------------------------------------------------

  defp enqueue(email, opts) do
    args = %{"email" => serialize(email), "opts" => serialize_opts(opts)}

    case args |> SendJob.new() |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} ->
        {:queued, log_uuid(email) || "job-#{id}"}

      {:error, reason} ->
        # Fall through to an inline send rather than drop the message: an Oban
        # that cannot accept jobs must not become a mail outage.
        Logger.error("[Emails.Queue] could not enqueue, sending inline: #{inspect(reason)}")
        :continue
    end
  rescue
    # `Oban.insert/1` only *returns* {:error, changeset} for a failed changeset —
    # a connection error, a pool timeout, a missing table or no running Oban
    # instance RAISES. Without this the raise escapes through deliver_email/2
    # into the caller, and the message is neither queued nor sent: exactly the
    # outage the clause above exists to prevent, just via the other door.
    error ->
      Logger.error("[Emails.Queue] enqueue raised, sending inline: #{Exception.message(error)}")

      :continue
  catch
    # DBConnection ownership errors (sandbox, checkout timeouts) exit rather than
    # raise. Same verdict: send it now.
    :exit, reason ->
      Logger.error("[Emails.Queue] enqueue exited, sending inline: #{inspect(reason)}")
      :continue
  end

  # One clause: `Swoosh.Email`'s `headers` is always a map (the struct default),
  # so a fallback clause is unreachable and dialyzer says so.
  defp log_uuid(%Email{headers: headers}), do: Map.get(headers, @log_header)

  @doc """
  Serializes a `Swoosh.Email` into JSON-safe job args.

  Only the fields a send needs: recipients, subject, bodies and headers. The
  tracking header rides along, which is what makes the worker's send reuse the
  log row this message already has instead of writing a second one.

  Deliberately **dropped**: `attachments` (queued mail with attachments is sent
  inline instead — see the moduledoc), and `provider_options` / `assigns` /
  `private`, which are not JSON-safe in the general case. Nothing sets
  `provider_options` per-email today; if that changes, round-trip it here or
  queued mail will silently lose options that an inline send keeps. (The SES
  configuration set and message tags travel as *headers*, so those are kept.)

  > #### Recipients and bodies land in `oban_jobs` {: .warning}
  >
  > Queued mail carries its full body in the job's args until the row is
  > pruned — independent of `email_save_body` and of `email_retention_days`,
  > which only govern this module's own tables. A deployment that keeps
  > completed jobs forever keeps the message content forever; configure
  > `Oban.Plugins.Pruner` accordingly.
  """
  @spec serialize(Email.t()) :: map()
  def serialize(%Email{} = email) do
    %{
      "to" => serialize_recipients(email.to),
      "from" => serialize_recipient(email.from),
      "cc" => serialize_recipients(email.cc),
      "bcc" => serialize_recipients(email.bcc),
      "reply_to" => serialize_recipient(email.reply_to),
      "subject" => email.subject,
      "text_body" => email.text_body,
      "html_body" => email.html_body,
      "headers" => email.headers || %{}
    }
  end

  @doc "Rebuilds the `Swoosh.Email` a `serialize/1` produced."
  @spec deserialize(map()) :: Email.t()
  def deserialize(%{} = data) do
    Email.new()
    |> put_recipients(:to, data["to"])
    |> put_from(data["from"])
    |> put_recipients(:cc, data["cc"])
    |> put_recipients(:bcc, data["bcc"])
    |> put_reply_to(data["reply_to"])
    |> Email.subject(data["subject"] || "")
    |> put_body(:text, data["text_body"])
    |> put_body(:html, data["html_body"])
    |> put_headers(data["headers"])
  end

  defp serialize_recipients(nil), do: []
  defp serialize_recipients(list) when is_list(list), do: Enum.map(list, &serialize_recipient/1)
  defp serialize_recipients(one), do: [serialize_recipient(one)]

  defp serialize_recipient(nil), do: nil
  defp serialize_recipient({name, address}), do: [name, address]
  defp serialize_recipient(address) when is_binary(address), do: ["", address]

  defp deserialize_recipient([name, address]), do: {name || "", address}
  defp deserialize_recipient(address) when is_binary(address), do: {"", address}
  defp deserialize_recipient(_), do: nil

  defp put_recipients(email, _field, nil), do: email
  defp put_recipients(email, _field, []), do: email

  defp put_recipients(email, field, list) when is_list(list) do
    recipients = list |> Enum.map(&deserialize_recipient/1) |> Enum.reject(&is_nil/1)

    case field do
      :to -> Email.to(email, recipients)
      :cc -> Email.cc(email, recipients)
      :bcc -> Email.bcc(email, recipients)
    end
  end

  defp put_from(email, nil), do: email
  defp put_from(email, value), do: Email.from(email, deserialize_recipient(value))

  defp put_reply_to(email, nil), do: email
  defp put_reply_to(email, value), do: Email.reply_to(email, deserialize_recipient(value))

  defp put_body(email, _kind, nil), do: email
  defp put_body(email, :text, body), do: Email.text_body(email, body)
  defp put_body(email, :html, body), do: Email.html_body(email, body)

  defp put_headers(email, headers) when is_map(headers) do
    Enum.reduce(headers, email, fn {key, value}, acc -> Email.header(acc, key, value) end)
  end

  defp put_headers(email, _headers), do: email

  @doc false
  # Exposed for tests: the allowlist is the reason a job's args cannot carry a
  # caller's secrets into the jobs table, which is worth pinning down.
  def serialize_opts_for_test(opts), do: serialize_opts(opts)

  # Only the opts the send path actually reads survive the round trip — they
  # have to be JSON-safe, and a worker resurrecting arbitrary caller state is a
  # bug waiting to happen.
  defp serialize_opts(opts) do
    opts
    |> Keyword.take([:campaign_id, :template_name, :provider, :user_uuid])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  @doc "Turns `serialize_opts/1` output back into the keyword list the mailer takes."
  @spec deserialize_opts(map()) :: keyword()
  def deserialize_opts(opts) when is_map(opts) do
    for {key, value} <- opts,
        key in ~w(campaign_id template_name provider user_uuid),
        do: {String.to_existing_atom(key), value}
  end

  def deserialize_opts(_opts), do: []
end
