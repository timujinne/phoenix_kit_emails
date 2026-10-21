defmodule PhoenixKit.Modules.Emails.Verification.Smtp.Direct do
  @moduledoc """
  The SMTP session of the built-in runner (`email_verify_smtp_mode` = `"local"`): the
  server itself opens the connection. It is the same dialogue, and gives the same report,
  as the PowerShell runner (`priv/smtp_runner/pk-smtp-runner.ps1`, function
  `Invoke-SmtpSession`); `priv/smtp_runner/test_vectors.json` is replayed against both.

  `run/3` takes a session as `SmtpQueue.claim/3` hands it out and returns the result
  entry `SmtpQueue.report/4` takes (string keys):

      %{"lease", "mx_used", "outcome", "steps", "rcpt", "ms"}

  ## The dialogue

  At most two mail hosts, in the order given; the next one is tried only when the
  previous never gave a usable (2xx) banner. On a host: banner, `EHLO` (`HELO` if the
  reply is 5xx), `MAIL FROM`, `RCPT TO` of the probe address when the session has one,
  `RCPT TO` of every address, `QUIT`. **`DATA` is never sent**: no mail is ever
  transmitted. A reply may span several lines; its texts are joined with a line break
  and cut to 512 characters. A 421 anywhere ends the session without `QUIT`.

  `outcome` is `"answered"` (the dialogue ran as far as the host let it, a refusal
  included), `"connect_failed"`, `"timeout"` or `"reset"` (the host hung up, or spoke
  nonsense). Sockets are passive (`active: false`) and every wait has a deadline: the
  connect timeout, the read timeout of each reply, and 240 seconds for the whole session.

  ## The sender

  `MAIL FROM` is required: without a usable address nothing is connected and
  `{:error, :no_mail_from}` comes back. The `EHLO` name is `:helo` of the settings, or
  `localhost` when it is missing or not a plain host name.

  ## Where it connects

  Port 25, or, for tests, `opts[:port]` / the application env
  `:verification_smtp_port`. With the application env `:verification_smtp_loopback_only`
  set (the test config does) it refuses to connect anywhere but 127.0.0.0/8 and `::1`
  and raises instead: a test can never reach a real mail host.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config

  @default_port 25
  @max_hosts 2
  @text_limit 512
  @hard_ms Config.session_hard_limit_s() * 1000
  @quit_ms 3_000
  @send_timeout_ms 10_000
  @max_line 4096
  @max_reply_lines 100
  @port_hard_ms 120_000

  @address ~r/\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]{1,64}@[A-Za-z0-9.-]{1,255}\z/
  @reply_line ~r/\A[0-9]{3}(?:[ -]|\z)/

  @type session :: %{
          required(:lease) => String.t(),
          required(:mx) => [String.t()],
          optional(:domain) => String.t(),
          optional(:probe) => String.t() | nil,
          required(:rcpt) => [%{id: String.t(), email: String.t()}]
        }
  @type settings :: %{
          required(:mail_from) => String.t() | nil,
          optional(:helo) => String.t() | nil,
          optional(:connect_timeout_s) => pos_integer(),
          optional(:read_timeout_s) => pos_integer()
        }
  @type port_check :: %{state: String.t(), banner: String.t(), detail: String.t()}

  ## --- A session ---

  @doc "The longest one session may run, in milliseconds (`run/3` gives up after it)."
  @spec hard_limit_ms() :: pos_integer()
  def hard_limit_ms, do: @hard_ms

  @doc """
  Runs `session` and returns its result entry. Options (tests): `:port`, `:hard_ms`.
  """
  @spec run(session(), settings(), keyword()) :: {:ok, map()} | {:error, :no_mail_from}
  def run(session, settings, opts \\ []) do
    with {:ok, cfg} <- config(settings, opts) do
      started = now_ms()
      hard = started + Keyword.get(opts, :hard_ms, @hard_ms)
      attempt = try_hosts(Map.get(session, :mx, []), session, cfg, hard)
      {:ok, result(session, attempt, now_ms() - started)}
    end
  end

  defp config(settings, opts) do
    case valid_address(Map.get(settings, :mail_from)) do
      nil ->
        {:error, :no_mail_from}

      mail_from ->
        {:ok,
         %{
           mail_from: mail_from,
           helo: helo(Map.get(settings, :helo)),
           port: Keyword.get(opts, :port) || configured_port(),
           connect_ms: seconds_ms(Map.get(settings, :connect_timeout_s), 20),
           read_ms: seconds_ms(Map.get(settings, :read_timeout_s), 30)
         }}
    end
  end

  defp helo(name) when is_binary(name) do
    if Config.helo_name?(name), do: name, else: "localhost"
  end

  defp helo(_name), do: "localhost"

  defp seconds_ms(seconds, _default) when is_integer(seconds) and seconds > 0, do: seconds * 1000
  defp seconds_ms(_seconds, default), do: default * 1000

  defp configured_port do
    case Application.get_env(:phoenix_kit_emails, :verification_smtp_port, @default_port) do
      port when is_integer(port) and port in 1..65_535 -> port
      _ -> @default_port
    end
  end

  # At most two mail hosts; the next one only when this one gave no usable banner.
  defp try_hosts(hosts, session, cfg, hard) do
    hosts
    |> Enum.take(@max_hosts)
    |> Enum.reduce_while(nil, fn host, _previous ->
      attempt = attempt(to_string(host), session, cfg, hard)
      if attempt.greeted?, do: {:halt, attempt}, else: {:cont, attempt}
    end)
  end

  defp result(session, nil, ms) do
    %{
      "lease" => session.lease,
      "mx_used" => nil,
      "outcome" => "connect_failed",
      "steps" => [],
      "rcpt" => [],
      "ms" => ms
    }
  end

  defp result(session, attempt, ms) do
    %{
      "lease" => session.lease,
      "mx_used" => attempt.host,
      "outcome" => attempt.outcome,
      "steps" => Enum.reverse(attempt.steps),
      "rcpt" => Enum.reverse(attempt.rcpt),
      "ms" => ms
    }
  end

  ## --- One attempt at one host ---

  defp attempt(host, session, cfg, hard) do
    state = %{
      host: host,
      sock: nil,
      buf: <<>>,
      hard: hard,
      read_ms: cfg.read_ms,
      steps: [],
      rcpt: [],
      greeted?: false,
      quit?: true,
      outcome: "answered"
    }

    case connect_within_session(host, cfg, hard) do
      {:ok, sock} ->
        try do
          %{state | sock: sock} |> dialogue(session, cfg) |> quit()
        after
          :gen_tcp.close(sock)
        end

      :error ->
        %{state | outcome: "connect_failed"}
    end
  end

  @doc false
  # The connect wait, cut to what is left of the session: the limit counts from the start,
  # so a long connect wait must not outlive it. `:expired` when nothing is left.
  @spec connect_budget(
          %{required(:connect_ms) => pos_integer(), optional(atom()) => term()},
          integer(),
          integer()
        ) ::
          {:ok, pos_integer()} | :expired
  def connect_budget(%{connect_ms: connect_ms}, hard, now) when hard > now,
    do: {:ok, min(connect_ms, hard - now)}

  def connect_budget(_cfg, _hard, _now), do: :expired

  defp connect_within_session(host, cfg, hard) do
    case connect_budget(cfg, hard, now_ms()) do
      {:ok, wait_ms} -> connect(host, cfg.port, wait_ms)
      :expired -> :error
    end
  end

  @phases [:banner, :greeting, :mail_from, :probe, :recipients]

  defp dialogue(state, session, cfg) do
    Enum.reduce_while(@phases, state, fn phase, state ->
      case phase(phase, state, session, cfg) do
        {:cont, state} -> {:cont, state}
        {:halt, state} -> {:halt, state}
        {:fail, state, outcome} -> {:halt, %{state | outcome: outcome, quit?: false}}
      end
    end)
  end

  defp phase(:banner, state, _session, _cfg) do
    case read_reply(state, state.read_ms) do
      {:ok, reply, state} ->
        state = add_step(state, "banner", reply)

        if success?(reply),
          do: {:cont, %{state | greeted?: true}},
          else: {:halt, %{state | quit?: false}}

      {:error, outcome} ->
        {:fail, state, outcome}
    end
  end

  defp phase(:greeting, state, _session, cfg) do
    with {:ok, reply, state} <- command(state, "EHLO " <> cfg.helo),
         {:ok, reply, state} <- helo_if_refused(reply, state, cfg) do
      state = add_step(state, "ehlo", reply)
      refused(state, reply)
    else
      {:error, outcome} -> {:fail, state, outcome}
    end
  end

  defp phase(:mail_from, state, _session, cfg) do
    case command(state, "MAIL FROM:<" <> cfg.mail_from <> ">") do
      {:ok, reply, state} -> state |> add_step("mail", reply) |> refused(reply)
      {:error, outcome} -> {:fail, state, outcome}
    end
  end

  defp phase(:probe, state, session, _cfg) do
    case valid_address(Map.get(session, :probe)) do
      nil ->
        {:cont, state}

      probe ->
        case command(state, "RCPT TO:<" <> probe <> ">") do
          {:ok, reply, state} -> state |> add_step("rcpt_probe", reply) |> after_probe(reply)
          {:error, outcome} -> {:fail, state, outcome}
        end
    end
  end

  defp phase(:recipients, state, session, _cfg) do
    session
    |> Map.get(:rcpt, [])
    |> Enum.reduce_while({:cont, state}, fn item, {:cont, state} ->
      case valid_address(item.email) do
        nil -> {:cont, {:cont, state}}
        address -> recipient(state, item.id, address)
      end
    end)
  end

  defp recipient(state, id, address) do
    case command(state, "RCPT TO:<" <> address <> ">") do
      {:ok, %{code: 421} = reply, state} ->
        {:halt, {:halt, %{add_rcpt(state, id, reply) | quit?: false}}}

      {:ok, reply, state} ->
        {:cont, {:cont, add_rcpt(state, id, reply)}}

      {:error, outcome} ->
        {:halt, {:fail, state, outcome}}
    end
  end

  defp helo_if_refused(%{code: code}, state, cfg) when code >= 500,
    do: command(state, "HELO " <> cfg.helo)

  defp helo_if_refused(reply, state, _cfg), do: {:ok, reply, state}

  # A reply of 300 and over ends the dialogue; a 421 means the host is hanging up.
  defp refused(state, %{code: code}) when code >= 300,
    do: {:halt, %{state | quit?: code != 421}}

  defp refused(state, _reply), do: {:cont, state}

  defp after_probe(state, %{code: 421}), do: {:halt, %{state | quit?: false}}
  defp after_probe(state, _reply), do: {:cont, state}

  defp success?(%{code: code}), do: code >= 200 and code < 300

  defp add_step(state, cmd, reply),
    do: %{
      state
      | steps: [%{"cmd" => cmd, "code" => reply.code, "text" => reply.text} | state.steps]
    }

  defp add_rcpt(state, id, reply),
    do: %{state | rcpt: [%{"id" => id, "code" => reply.code, "text" => reply.text} | state.rcpt]}

  # QUIT is a courtesy: whatever comes of it does not change the result.
  defp quit(%{quit?: true} = state) do
    _ = command(state, "QUIT", @quit_ms)
    state
  end

  defp quit(state), do: state

  ## --- The port check ---

  @doc """
  The self-test of port 25: connects to `host`, reads the banner and says `QUIT`
  (the `Test-SmtpPort` of the runner script). `state` is `"open"` (a 220 banner),
  `"blocked"` (no connection) or `"unknown"` (connected, but no usable banner).
  Options: `:port`; `:connect_timeout_s` and `:read_timeout_s` come from `settings`.
  """
  @spec check_port(String.t(), map(), keyword()) :: port_check()
  def check_port(host, settings \\ %{}, opts \\ []) when is_binary(host) do
    cfg = %{
      port: Keyword.get(opts, :port) || configured_port(),
      connect_ms: seconds_ms(Map.get(settings, :connect_timeout_s), 20)
    }

    read_ms = seconds_ms(Map.get(settings, :read_timeout_s), 30)

    case connect(host, cfg.port, cfg.connect_ms) do
      {:ok, sock} ->
        try do
          state = %{
            sock: sock,
            buf: <<>>,
            hard: now_ms() + @port_hard_ms,
            read_ms: read_ms
          }

          banner_check(state, read_ms)
        after
          :gen_tcp.close(sock)
        end

      :error ->
        %{state: "blocked", banner: "", detail: "connect"}
    end
  end

  defp banner_check(state, read_ms) do
    case read_reply(state, read_ms) do
      {:ok, %{code: 220} = reply, state} ->
        _ = command(state, "QUIT", @quit_ms)
        %{state: "open", banner: banner_text(reply), detail: ""}

      {:ok, reply, _state} ->
        %{state: "unknown", banner: banner_text(reply), detail: ""}

      {:error, outcome} ->
        %{state: "unknown", banner: "", detail: outcome}
    end
  end

  defp banner_text(%{code: code, text: text}), do: Integer.to_string(code) <> " " <> text

  ## --- The socket ---

  defp connect(host, port, wait_ms) do
    guard!(host)

    options = [
      :binary,
      active: false,
      packet: :raw,
      nodelay: true,
      send_timeout: @send_timeout_ms,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(String.to_charlist(host), port, options, wait_ms) do
      {:ok, sock} -> {:ok, sock}
      {:error, _reason} -> :error
    end
  end

  # The test config switches this on: no test can reach a real mail host.
  defp guard!(host) do
    if Application.get_env(:phoenix_kit_emails, :verification_smtp_loopback_only, false) and
         not loopback?(host) do
      raise ArgumentError,
            "refusing to connect to #{inspect(host)}: :verification_smtp_loopback_only is set"
    end
  end

  defp loopback?("localhost"), do: true

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  # Sends one command line and reads its reply. `{:error, outcome}` when the host went
  # silent (`"timeout"`) or the connection broke or the host spoke nonsense (`"reset"`).
  defp command(state, line, timeout_ms \\ nil) do
    case :gen_tcp.send(state.sock, line <> "\r\n") do
      :ok -> read_reply(state, timeout_ms || state.read_ms)
      {:error, _reason} -> {:error, "reset"}
    end
  end

  # A whole reply: lines up to the first whose fourth character is not "-".
  defp read_reply(state, timeout_ms), do: read_reply(state, now_ms() + timeout_ms, [])

  defp read_reply(state, deadline, texts) do
    with {:ok, line, state} <- read_line(state, deadline),
         {:ok, code, more?, text} <- parse_line(line) do
      texts = [text | texts]

      cond do
        not more? -> {:ok, %{code: code, text: join(texts)}, state}
        length(texts) >= @max_reply_lines -> {:error, "reset"}
        true -> read_reply(state, deadline, texts)
      end
    end
  end

  defp parse_line(line) do
    if Regex.match?(@reply_line, line) do
      <<code::binary-size(3), _rest::binary>> = line
      more? = String.at(line, 3) == "-"
      {:ok, String.to_integer(code), more?, String.slice(line, 4..-1//1)}
    else
      {:error, "reset"}
    end
  end

  defp join(texts) do
    texts
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.slice(0, @text_limit)
  end

  # One line without its line break; waits until `deadline` (and the session's hard
  # limit).
  defp read_line(state, deadline) do
    case :binary.split(state.buf, "\n") do
      [line, rest] ->
        {:ok, line |> String.trim_trailing("\r") |> utf8(), %{state | buf: rest}}

      [_incomplete] when byte_size(state.buf) > @max_line ->
        {:error, "reset"}

      [_incomplete] ->
        receive_more(state, deadline)
    end
  end

  defp receive_more(state, deadline) do
    left = min(deadline, state.hard) - now_ms()

    if left <= 0 do
      {:error, "timeout"}
    else
      case :gen_tcp.recv(state.sock, 0, left) do
        {:ok, data} -> read_line(%{state | buf: state.buf <> data}, deadline)
        {:error, :timeout} -> {:error, "timeout"}
        {:error, _reason} -> {:error, "reset"}
      end
    end
  end

  defp utf8(line) do
    if String.valid?(line),
      do: line,
      else: :unicode.characters_to_binary(line, :latin1)
  end

  ## --- Helpers ---

  defp valid_address(address) when is_binary(address) do
    if Regex.match?(@address, address), do: address
  end

  defp valid_address(_address), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)
end
