defmodule PhoenixKit.Modules.Emails.Verification.Classifier do
  @moduledoc """
  Turns the raw facts of one SMTP session into a verdict per address.

  A runner only reports what the mail host said (reply codes and texts, and how the
  connection ended); this module decides what it means, on the server, so the
  phrase lists never leave it. It is pure: no database, no network. The queue
  (`Verification.SmtpQueue`) applies the result.

  ## Input

  A session is a map with atom keys:

    * `:outcome` - `"answered"`, `"connect_failed"`, `"timeout"` or `"reset"`
    * `:steps` - `[%{cmd:, code:, text:}]`, `cmd` being `"banner"`, `"ehlo"`,
      `"mail"` or `"rcpt_probe"` (the random-address probe of the catch-all check)
    * `:rcpt` - `[%{id:, code:, text:}]`, the reply to each address's `RCPT TO`

  Options: `:catch_all` - the domain's cached catch-all fact (`true`, `false`, or
  `nil` for unknown; free and disposable domains are passed as `false`, as nobody
  probes them), `:phrases` - a map `%{grey:, quota:, block:, user_unknown:}` of
  phrase lists (default: `Dictionaries.phrases/1`).

  ## The table

  | Fact | Verdict |
  |---|---|
  | `rcpt_probe` 2xx | domain is catch-all |
  | `rcpt_probe` 5xx | domain is not catch-all (unless the text is a block) |
  | `RCPT` 250/251, domain not catch-all | `valid` / `smtp_ok`, level `smtp` |
  | `RCPT` 250/251, domain catch-all | `not_sure` / `catch_all` |
  | `RCPT` 5xx, quota phrase | `temp` / `mailbox_full` |
  | `RCPT` 5xx, greylist phrase | retry later (like a 4xx) |
  | `RCPT` 5xx, block phrase, any IP address or an enhanced status 5.7.x in the text, and not a user-unknown text | `not_sure` / `smtp_blocked`, one block for the domain |
  | `RCPT` 5xx, anything else | `invalid` / `mailbox_unknown` |
  | `RCPT` 4xx | retry later; once the attempts are spent `temp` / `greylisted` |
  | `MAIL FROM` 5xx | `not_sure` / `mail_from_rejected` |
  | `MAIL FROM` 4xx | like `RCPT` 4xx |
  | banner or `EHLO` 5xx | `not_sure` / `smtp_blocked`, one block for the domain |
  | banner or `EHLO` 4xx | retry later; at last `not_sure` / `smtp_unavailable` |
  | `connect_failed` / `timeout` / `reset` | retry with backoff; at last `not_sure` / `smtp_connect_failed` / `smtp_timeout` / `smtp_reset` |

  Where the table lists no order, the order of Kellerman's engine is kept: a quota
  phrase first, then greylist, then block. A user-unknown text ("user unknown",
  "5.1.1", ...) is never a greylist or a block, so a refusal that merely quotes
  an IP address is still an unknown mailbox. IP addresses are removed from the text
  before the user-unknown phrases are looked for (so `5.1.1.9` is not `5.1.1`).
  A 5xx whose enhanced status is 5.7.x (security or policy) and which holds no
  user-unknown phrase is a block, never an unknown mailbox: a refusal such as
  "5.7.1 reverse DNS for your IP does not exist" is about the sender.

  ## Output

      %{
        verdicts: %{id => verdict},
        domain: %{catch_all: true | false | nil, blocked: boolean, grey_message: String.t() | nil},
        failed: boolean
      }

  `domain.catch_all` is what this session's probe proved (`nil` when there was no
  probe or it proved nothing): the cached fact passed in with `:catch_all` shapes
  the verdicts but is not echoed back, so the queue refreshes the domain's catch-all
  timestamp only when a probe really ran.

  A verdict is either final

      %{action: :final, status: "valid", reason: "smtp_ok", level: "smtp", catch_all: false}

  or a request to try again, with the verdict to keep once the attempts run out:

      %{action: :retry, kind: :grey | :transport,
        exhausted: %{status:, reason:, level:, catch_all:}}

  `failed` is whether the session counts against the runner (the connection failed,
  or the host blocked it): five such sessions in a row on three domains pause the
  runner.
  """

  alias PhoenixKit.Modules.Emails.Verification.Dictionaries

  @type step :: %{cmd: String.t(), code: integer(), text: String.t()}
  @type session :: %{
          required(:outcome) => String.t(),
          required(:steps) => [step()],
          required(:rcpt) => [%{id: term(), code: integer(), text: String.t()}],
          optional(atom()) => term()
        }
  @type phrases :: %{
          grey: [String.t()],
          quota: [String.t()],
          block: [String.t()],
          user_unknown: [String.t()]
        }
  @type verdict ::
          %{
            action: :final,
            status: String.t(),
            reason: String.t(),
            level: String.t(),
            catch_all: boolean() | nil
          }
          | %{action: :retry, kind: :grey | :transport, exhausted: map(), text: String.t() | nil}
  @type result :: %{
          verdicts: %{term() => verdict()},
          domain: %{
            catch_all: boolean() | nil,
            blocked: boolean(),
            grey_message: String.t() | nil
          },
          failed: boolean()
        }

  @transport_reasons %{
    "connect_failed" => "smtp_connect_failed",
    "timeout" => "smtp_timeout",
    "reset" => "smtp_reset"
  }

  @doc "The phrase lists the classifier uses, read from `Dictionaries`."
  @spec phrases() :: phrases()
  def phrases do
    %{
      grey: Dictionaries.phrases(:smtp_grey),
      quota: Dictionaries.phrases(:smtp_quota),
      block: Dictionaries.phrases(:smtp_block),
      user_unknown: Dictionaries.phrases(:smtp_user_unknown)
    }
  end

  @doc """
  Classifies `session` for the addresses `ids` (the leased addresses, in the order
  the verdicts are wanted). An address the runner reported nothing about falls back
  to what the connection's outcome says.
  """
  @spec classify(session(), [term()], keyword()) :: result()
  def classify(session, ids, opts \\ []) do
    ctx = %{phrases: prepare(Keyword.get_lazy(opts, :phrases, &phrases/0))}
    steps = Map.new(session.steps, &{&1.cmd, &1})
    rcpt = Map.new(session.rcpt, &{&1.id, &1})
    cached = Keyword.get(opts, :catch_all)

    case session_fault(session.outcome, steps) do
      {:all, verdict, failure} ->
        verdicts = Map.new(ids, &{&1, verdict})
        result(verdicts, nil, failure == :blocked, failure != nil)

      :none ->
        probe = probe_result(steps["rcpt_probe"], ctx)
        catch_all = if is_nil(probe), do: cached, else: probe
        verdicts = Map.new(ids, &{&1, address(rcpt[&1], session.outcome, catch_all, ctx)})
        blocked? = Enum.any?(verdicts, fn {_id, verdict} -> blocked?(verdict) end)

        result(verdicts, probe, blocked?, blocked? or session.outcome == "connect_failed")
    end
  end

  defp result(verdicts, probe, blocked?, failed?) do
    %{
      verdicts: verdicts,
      domain: %{catch_all: probe, blocked: blocked?, grey_message: grey_message(verdicts)},
      failed: failed?
    }
  end

  ## --- Faults that cover the whole session ---

  # A connection that never got going has nothing to say about any mailbox.
  defp session_fault("connect_failed", _steps),
    do: {:all, transport("smtp_connect_failed"), :connect_failed}

  defp session_fault(_outcome, steps) do
    with :none <- greeting_fault(steps["banner"]),
         :none <- greeting_fault(steps["ehlo"]) do
      mail_fault(steps["mail"])
    end
  end

  defp greeting_fault(nil), do: :none
  defp greeting_fault(%{code: code}) when code < 400, do: :none

  defp greeting_fault(%{code: code}) when code < 500,
    do: {:all, transport("smtp_unavailable"), nil}

  defp greeting_fault(_refused),
    do: {:all, final("not_sure", "smtp_blocked", "smtp", nil), :blocked}

  defp mail_fault(nil), do: :none
  defp mail_fault(%{code: code}) when code < 400, do: :none
  defp mail_fault(%{code: code, text: text}) when code < 500, do: {:all, grey(text), nil}

  defp mail_fault(_refused),
    do: {:all, final("not_sure", "mail_from_rejected", "smtp", nil), nil}

  ## --- The catch-all probe ---

  defp probe_result(nil, _ctx), do: nil
  defp probe_result(%{code: code}, _ctx) when code in 200..299, do: true

  defp probe_result(%{code: code, text: text}, ctx) when code >= 500 do
    if block_text?(text, ctx), do: nil, else: false
  end

  defp probe_result(_inconclusive, _ctx), do: nil

  ## --- One address ---

  defp address(nil, outcome, _catch_all, _ctx),
    do: transport(Map.get(@transport_reasons, outcome, "smtp_reset"))

  defp address(%{code: code}, _outcome, catch_all, _ctx) when code in 200..299 do
    if catch_all == true,
      do: final("not_sure", "catch_all", "smtp", true),
      else: final("valid", "smtp_ok", "smtp", catch_all)
  end

  defp address(%{code: code, text: text}, _outcome, _catch_all, _ctx) when code in 400..499,
    do: grey(text)

  defp address(%{text: text}, _outcome, _catch_all, ctx), do: refusal(text, ctx)

  # A 5xx reply (or one with a code that is neither 2xx nor 4xx).
  defp refusal(text, ctx) do
    text_norm = normalized(text)

    cond do
      matches?(text_norm, ctx.phrases.quota) ->
        final("temp", "mailbox_full", "smtp", nil)

      not unknown_user?(text, ctx) and matches?(text_norm, ctx.phrases.grey) ->
        grey(text)

      block_text?(text, ctx) ->
        final("not_sure", "smtp_blocked", "smtp", nil)

      true ->
        final("invalid", "mailbox_unknown", "smtp", nil)
    end
  end

  # A block phrase, any IP address or an enhanced status 5.7.x (a policy refusal) in
  # the text - unless the text says the mailbox does not exist.
  defp block_text?(text, ctx) do
    not unknown_user?(text, ctx) and
      (matches?(normalized(text), ctx.phrases.block) or contains_ip?(text) or
         policy_status?(text))
  end

  defp unknown_user?(text, ctx),
    do: text |> strip_ips() |> normalized() |> matches?(ctx.phrases.user_unknown)

  ## --- Verdict constructors ---

  defp final(status, reason, level, catch_all),
    do: %{action: :final, status: status, reason: reason, level: level, catch_all: catch_all}

  defp grey(text) do
    %{
      action: :retry,
      kind: :grey,
      text: text,
      exhausted: exhausted("temp", "greylisted", "smtp")
    }
  end

  defp transport(reason) do
    %{action: :retry, kind: :transport, exhausted: exhausted("not_sure", reason, "mx")}
  end

  defp exhausted(status, reason, level),
    do: %{status: status, reason: reason, level: level, catch_all: nil}

  defp blocked?(%{action: :final, reason: "smtp_blocked"}), do: true
  defp blocked?(_verdict), do: false

  # The text of the first reply that asked to wait, to remember on the domain.
  defp grey_message(verdicts) do
    Enum.find_value(verdicts, fn
      {_id, %{action: :retry, kind: :grey, text: text}} -> text
      _ -> nil
    end)
  end

  ## --- Text matching ---

  defp prepare(phrases) do
    Map.new(phrases, fn {kind, list} ->
      {kind, list |> Enum.map(&normalized/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
    end)
  end

  # Everything but letters and digits is a separator; the text is padded so a
  # phrase has to match whole words.
  defp normalized(text) when is_binary(text) do
    words = text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, " ") |> String.trim()
    if words == "", do: "", else: " " <> words <> " "
  end

  defp normalized(_text), do: ""

  defp matches?("", _phrases), do: false
  defp matches?(text_norm, phrases), do: Enum.any?(phrases, &String.contains?(text_norm, &1))

  @ip_candidate ~r/[0-9a-fA-F:.]{3,45}/
  @policy_status ~r/(?<![0-9.])5\.7\.[0-9]{1,3}(?![0-9.])/

  # RFC 3463 class 5, subject 7: "security or policy status". An address in the text
  # is cut out first, so the start of `5.7.1.9` is not read as a status.
  defp policy_status?(text) when is_binary(text),
    do: Regex.match?(@policy_status, strip_ips(text))

  defp policy_status?(_text), do: false

  defp contains_ip?(text) when is_binary(text) do
    @ip_candidate |> Regex.scan(text) |> List.flatten() |> Enum.any?(&ip?/1)
  end

  defp contains_ip?(_text), do: false

  defp strip_ips(text) when is_binary(text) do
    Regex.replace(@ip_candidate, text, fn candidate ->
      if ip?(candidate), do: " ", else: candidate
    end)
  end

  defp strip_ips(_text), do: ""

  # Strict forms only: `:inet.parse_address/1` also reads "5.1.1" as an address.
  defp ip?(candidate) do
    charlist = candidate |> String.trim(".") |> String.to_charlist()

    match?({:ok, _}, :inet.parse_ipv4strict_address(charlist)) or
      match?({:ok, _}, :inet.parse_ipv6strict_address(charlist))
  end
end
