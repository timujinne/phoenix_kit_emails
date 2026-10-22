defmodule PhoenixKitEmails.Test.FakeSmtpServer do
  @moduledoc """
  A scripted fake mail host for the tests of the built-in SMTP runner. It listens on
  127.0.0.1 on an ephemeral port and nothing else: tests hand that port to
  `Verification.Smtp.Direct` and never connect to a real server.

  The script is the `smtp` part of a vector of `priv/smtp_runner/test_vectors.json`
  (the Python fake of the Pester suite reads the same format):

    * `"listen"` - `false`: a port that was bound and closed, so a connection is refused
    * `"banner"` - lines sent on connect (`nil`: nothing); `"banner_then": "close"` hangs up
    * `"rules"` - `[%{"match" => regex, "reply" => [lines], "then" => "close",
      "hang" => true, "delay" => seconds}]`; the first rule whose regex matches the
      command wins; `hang` reads on and never answers
    * an unmatched command gets 500; `QUIT` gets 221 and a close; `DATA` gets 554 (the
      tests assert it never comes)
  """

  @type t :: %{port: :inet.port_number(), log: pid(), listener: port() | nil}

  @doc "Starts a server for `spec` (a map with string keys). Stopped with the caller."
  @spec start(map()) :: t()
  def start(spec) do
    {:ok, log} =
      Agent.start_link(fn -> %{commands: [], connections: 0, active: 0, peak: 0} end)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        reuseaddr: true,
        backlog: 32
      ])

    {:ok, port} = :inet.port(listener)

    if Map.get(spec, "listen") == false do
      :gen_tcp.close(listener)
      %{port: port, log: log, listener: nil}
    else
      rules =
        for rule <- Map.get(spec, "rules", []), do: {Regex.compile!(rule["match"], "i"), rule}

      script = %{banner: Map.get(spec, "banner"), banner_then: spec["banner_then"], rules: rules}
      pid = spawn_link(fn -> accept(listener, script, log) end)
      :ok = :gen_tcp.controlling_process(listener, pid)
      %{port: port, log: log, listener: listener}
    end
  end

  @doc "A port nothing listens on."
  @spec closed_port() :: :inet.port_number()
  def closed_port, do: start(%{"listen" => false}).port

  @doc "Every command received, in order, across connections."
  @spec commands(t()) :: [String.t()]
  def commands(%{log: log}), do: log |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "How many connections were accepted."
  @spec connections(t()) :: non_neg_integer()
  def connections(%{log: log}), do: Agent.get(log, & &1.connections)

  @doc "The most connections open at the same time."
  @spec peak(t()) :: non_neg_integer()
  def peak(%{log: log}), do: Agent.get(log, & &1.peak)

  defp accept(listener, script, log) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock, script, log) end)
        _ = :gen_tcp.controlling_process(sock, pid)
        accept(listener, script, log)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(sock, script, log) do
    track(log, fn state ->
      active = state.active + 1

      %{state | connections: state.connections + 1, active: active, peak: max(state.peak, active)}
    end)

    try do
      greet(sock, script, log)
    after
      track(log, &%{&1 | active: &1.active - 1})
      :gen_tcp.close(sock)
    end
  end

  # The log ends with the test that started it; a connection that outlives it is not an error.
  defp track(log, fun) do
    Agent.update(log, fun)
  catch
    :exit, _ -> :ok
  end

  defp greet(sock, %{banner: banner} = script, log) do
    if banner, do: send_lines(sock, banner)
    if script.banner_then != "close", do: loop(sock, <<>>, script, log)
  end

  defp loop(sock, buffer, script, log) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        command = String.trim_trailing(line, "\r")
        track(log, &%{&1 | commands: [command | &1.commands]})

        case answer(sock, command, script) do
          :continue -> loop(sock, rest, script, log)
          :close -> :ok
        end

      [_incomplete] ->
        case :gen_tcp.recv(sock, 0) do
          {:ok, data} -> loop(sock, buffer <> data, script, log)
          {:error, _reason} -> :ok
        end
    end
  end

  defp answer(sock, command, script) do
    case Enum.find(script.rules, fn {regex, _rule} -> Regex.match?(regex, command) end) do
      {_regex, %{"hang" => true}} ->
        :continue

      {_regex, rule} ->
        if rule["delay"], do: Process.sleep(round(rule["delay"] * 1000))
        send_lines(sock, Map.get(rule, "reply", []))
        if rule["then"] == "close", do: :close, else: :continue

      nil ->
        default(sock, String.upcase(command))
    end
  end

  defp default(sock, "QUIT" <> _) do
    send_lines(sock, ["221 2.0.0 Bye"])
    :close
  end

  defp default(sock, "DATA" <> _) do
    send_lines(sock, ["554 5.5.1 no DATA here"])
    :continue
  end

  defp default(sock, _command) do
    send_lines(sock, ["500 5.5.1 command not recognized"])
    :continue
  end

  defp send_lines(sock, lines),
    do: :gen_tcp.send(sock, Enum.map(lines, &[&1, "\r\n"]))
end
