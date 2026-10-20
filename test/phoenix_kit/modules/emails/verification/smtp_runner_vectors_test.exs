defmodule PhoenixKit.Modules.Emails.Verification.SmtpRunnerVectorsTest do
  @moduledoc """
  The shared test vectors of the SMTP runner (`priv/smtp_runner/test_vectors.json`):
  the Pester suite replays them against the real script and a scripted fake mail
  host; this suite checks the vectors themselves, on the server side. The file is
  valid, every expected report passes the input schema of the report tool, and the
  classifier reads every expected report the way the vector says. No sockets here.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.API.Validator
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Verification.Classifier

  @path "priv/smtp_runner/test_vectors.json"

  @required_names ~w(normal_250 user_unknown_550 catch_all_probe_250 greylist_451 block_554_ip
                     banner_421 connect_refused timeout_mid_dialog ehlo_multiline ehlo_502_helo
                     mail_from_553)

  defp document, do: @path |> File.read!() |> JSON.decode!()
  defp vectors, do: document()["vectors"]

  defp report_tool, do: Enum.find(Emails.api_tools(), &(&1.name == "emails.report_smtp_results"))

  # Phrase lists as the vectors assume them: the shipped user-unknown phrases and
  # nothing private.
  defp phrases, do: %{Classifier.phrases() | grey: [], quota: [], block: []}

  test "the file is valid and holds the scenarios the runner contract needs" do
    assert document()["format"] == 1
    names = Enum.map(vectors(), & &1["name"])

    assert names == Enum.uniq(names)
    for name <- @required_names, do: assert(name in names, "missing vector #{name}")

    leases = Enum.map(vectors(), & &1["report"]["lease"])
    assert leases == Enum.uniq(leases)
  end

  test "every vector has the parts both suites read" do
    for vector <- vectors() do
      assert is_binary(vector["description"]), vector["name"]
      assert vector["rcpt"] != [], vector["name"]
      assert is_map(vector["smtp"]), vector["name"]
      assert is_list(vector["commands"]), vector["name"]

      ids = Enum.map(vector["rcpt"], & &1["id"])
      assert ids == Enum.uniq(ids)
      assert Map.keys(vector["classification"]["verdicts"]) |> Enum.sort() == Enum.sort(ids)

      for rule <- vector["smtp"]["rules"] || [] do
        assert {:ok, _} = Regex.compile(rule["match"]), vector["name"]
      end
    end
  end

  test "the runner never sends DATA in any vector" do
    for vector <- vectors(), command <- vector["commands"] do
      refute command =~ ~r/^DATA/i, vector["name"]
    end
  end

  test "every expected report passes the input schema of the report tool" do
    schema = report_tool().input_schema

    for vector <- vectors() do
      assert {:ok, _} = Validator.validate(schema, %{"results" => [vector["report"]]}),
             "#{vector["name"]}: the expected report is not accepted by the report tool"
    end
  end

  test "a report with an unknown field is refused (the check above is not vacuous)" do
    bad = Map.put(hd(vectors())["report"], "extra", 1)
    assert {:error, _} = Validator.validate(report_tool().input_schema, %{"results" => [bad]})
  end

  test "texts stay within the limit the server keeps" do
    for vector <- vectors(),
        reply <- vector["report"]["steps"] ++ vector["report"]["rcpt"] do
      assert String.length(reply["text"]) <= 512, vector["name"]
    end
  end

  test "the classifier reads every expected report the way the vector says" do
    for vector <- vectors() do
      report = vector["report"]
      expected = vector["classification"]

      session = %{
        outcome: report["outcome"],
        steps: Enum.map(report["steps"], &reply(&1, "cmd")),
        rcpt: Enum.map(report["rcpt"], &reply(&1, "id"))
      }

      ids = Enum.map(vector["rcpt"], & &1["id"])
      result = Classifier.classify(session, ids, phrases: phrases(), catch_all: nil)

      for {id, want} <- expected["verdicts"] do
        got = result.verdicts[id]

        for {key, value} <- want do
          assert to_string(Map.fetch!(got, String.to_existing_atom(key))) == value,
                 "#{vector["name"]}/#{id}: #{key} is #{inspect(Map.get(got, String.to_atom(key)))}, " <>
                   "the vector says #{value}"
        end
      end

      assert result.domain.catch_all == expected["domain"]["catch_all"], vector["name"]
      assert result.domain.blocked == expected["domain"]["blocked"], vector["name"]
      assert result.failed == expected["failed"], vector["name"]
    end
  end

  test "the vectors cover every kind of verdict the runner can provoke" do
    kinds =
      for vector <- vectors(), {_id, v} <- vector["classification"]["verdicts"] do
        {v["action"], v["kind"] || v["reason"]}
      end
      |> MapSet.new()

    for kind <- [
          {"final", "smtp_ok"},
          {"final", "catch_all"},
          {"final", "mailbox_unknown"},
          {"final", "smtp_blocked"},
          {"final", "mail_from_rejected"},
          {"retry", "grey"},
          {"retry", "transport"}
        ] do
      assert kind in kinds, "no vector for #{inspect(kind)}"
    end
  end

  defp reply(entry, key) do
    %{key_atom(key) => entry[key], code: entry["code"], text: entry["text"]}
  end

  defp key_atom("cmd"), do: :cmd
  defp key_atom("id"), do: :id
end
