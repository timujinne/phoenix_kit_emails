defmodule PhoenixKit.Modules.Emails.Verification.ClassifierTest do
  @moduledoc """
  The classification table, on fixture phrases (not the original tool's lists):
  every row of the table, the precedence between the phrase lists, the user-unknown
  exception for IP addresses, and the domain side effects.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Classifier

  @phrases %{
    grey: ["fixture grey phrase", "fixture grey other"],
    quota: ["fixture quota phrase", "fixture quota other"],
    block: ["fixture block phrase", "fixture block other"],
    user_unknown: ["user unknown", "5.1.1", "invalid recipient"]
  }

  @banner %{cmd: "banner", code: 220, text: "mx.example.ee ESMTP"}
  @ehlo %{cmd: "ehlo", code: 250, text: "mx.example.ee"}
  @mail %{cmd: "mail", code: 250, text: "2.1.0 Ok"}

  defp probe(code, text \\ "2.1.5 Ok"), do: %{cmd: "rcpt_probe", code: code, text: text}

  defp session(rcpt, opts \\ []) do
    %{
      outcome: Keyword.get(opts, :outcome, "answered"),
      steps: Keyword.get(opts, :steps, [@banner, @ehlo, @mail]),
      rcpt: rcpt
    }
  end

  defp classify(session, ids, opts \\ []),
    do: Classifier.classify(session, ids, Keyword.put_new(opts, :phrases, @phrases))

  defp one(code, text, opts \\ []) do
    result = classify(session([%{id: "a", code: code, text: text}], opts), ["a"], opts)
    {result.verdicts["a"], result}
  end

  defp final(verdict), do: {verdict.status, verdict.reason, verdict.level, verdict.catch_all}

  describe "RCPT accepted" do
    test "250 on a domain that is not catch-all is valid" do
      {verdict, result} = one(250, "2.1.5 Ok", catch_all: false)

      assert verdict.action == :final
      assert final(verdict) == {"valid", "smtp_ok", "smtp", false}
      assert result.domain == %{catch_all: nil, blocked: false, grey_message: nil}
      refute result.failed
    end

    test "251 is accepted the same way" do
      {verdict, _} = one(251, "User not local; will forward", catch_all: false)
      assert final(verdict) == {"valid", "smtp_ok", "smtp", false}
    end

    test "when nothing is known about catch-all the address is valid and catch_all stays nil" do
      {verdict, result} = one(250, "ok")
      assert final(verdict) == {"valid", "smtp_ok", "smtp", nil}
      assert result.domain.catch_all == nil
    end

    test "250 on a cached catch-all domain is not_sure / catch_all" do
      {verdict, result} = one(250, "ok", catch_all: true)
      assert final(verdict) == {"not_sure", "catch_all", "smtp", true}
      assert result.domain.catch_all == nil
    end
  end

  describe "the catch-all probe" do
    test "a probe the host accepts makes the domain catch-all and the address not_sure" do
      session =
        session([%{id: "a", code: 250, text: "ok"}], steps: [@banner, @ehlo, @mail, probe(250)])

      result = classify(session, ["a"], catch_all: nil)

      assert final(result.verdicts["a"]) == {"not_sure", "catch_all", "smtp", true}
      assert result.domain.catch_all == true
    end

    test "a probe the host refuses proves the domain is not catch-all: the address is valid" do
      session =
        session([%{id: "a", code: 250, text: "ok"}],
          steps: [@banner, @ehlo, @mail, probe(550, "5.1.1 user unknown")]
        )

      result = classify(session, ["a"], catch_all: nil)

      assert final(result.verdicts["a"]) == {"valid", "smtp_ok", "smtp", false}
      assert result.domain.catch_all == false
    end

    test "the probe overrides a stale cached value" do
      session =
        session([%{id: "a", code: 250, text: "ok"}],
          steps: [@banner, @ehlo, @mail, probe(550, "no such user")]
        )

      result = classify(session, ["a"], catch_all: true)
      assert result.domain.catch_all == false
    end

    test "a probe refused with a block text proves nothing" do
      session =
        session([%{id: "a", code: 250, text: "ok"}],
          steps: [@banner, @ehlo, @mail, probe(550, "blocked, fixture block other")]
        )

      result = classify(session, ["a"], catch_all: nil)

      assert result.domain.catch_all == nil
      assert final(result.verdicts["a"]) == {"valid", "smtp_ok", "smtp", nil}
    end

    test "a probe refused with an enhanced status 5.7.x proves nothing either" do
      session =
        session([%{id: "a", code: 250, text: "ok"}],
          steps: [@banner, @ehlo, @mail, probe(550, "5.7.1 relay denied")]
        )

      assert classify(session, ["a"], catch_all: nil).domain.catch_all == nil
    end

    test "a temporary refusal of the probe proves nothing either, the cached value still decides" do
      session =
        session([%{id: "a", code: 250, text: "ok"}],
          steps: [@banner, @ehlo, @mail, probe(450, "fixture grey phrase")]
        )

      cached = classify(session, ["a"], catch_all: true)
      assert cached.domain.catch_all == nil
      assert cached.verdicts["a"].reason == "catch_all"
      assert classify(session, ["a"]).domain.catch_all == nil
    end
  end

  describe "RCPT refused with a 5xx" do
    test "an ordinary refusal is invalid / mailbox_unknown" do
      {verdict, result} = one(550, "5.1.1 The email account does not exist")
      assert final(verdict) == {"invalid", "mailbox_unknown", "smtp", nil}
      refute result.failed
    end

    test "a refusal with no recognisable text is still an unknown mailbox" do
      for text <- ["", "No", "Rejected"] do
        {verdict, _} = one(550, text)
        assert final(verdict) == {"invalid", "mailbox_unknown", "smtp", nil}, inspect(text)
      end
    end

    test "a quota phrase is temp / mailbox_full" do
      {verdict, _} = one(552, "5.2.2 Mailbox fixture quota phrase")
      assert final(verdict) == {"temp", "mailbox_full", "smtp", nil}
    end

    test "a block phrase is not_sure / smtp_blocked, and it counts as a block and a failed session" do
      {verdict, result} = one(554, "5.7.1 Service unavailable; fixture block phrase")

      assert final(verdict) == {"not_sure", "smtp_blocked", "smtp", nil}
      assert result.domain.blocked
      assert result.failed
    end

    test "phrases match whole words in any punctuation and case" do
      {verdict, _} = one(550, "Fixture-Block-Phrase: ref 123")
      assert verdict.reason == "smtp_blocked"

      {verdict, _} = one(550, "prefixture block phrase")
      assert verdict.reason == "mailbox_unknown"
    end

    test "an enhanced status 5.7.x is a block unless the text says the mailbox does not exist" do
      for text <- [
            "5.7.1 reverse DNS for your IP does not exist",
            "550 5.7.25 sender rejected",
            "554 5.7.0 Message refused",
            "550-5.7.1 fixture text"
          ] do
        {verdict, result} = one(550, text)
        assert final(verdict) == {"not_sure", "smtp_blocked", "smtp", nil}, text
        assert result.domain.blocked
        assert result.failed
      end

      {verdict, _} = one(550, "5.7.1 user unknown")
      assert verdict.reason == "mailbox_unknown"
    end

    test "5.7.x inside another number is not an enhanced status" do
      for text <- ["550 code 15.7.1 gone", "550 5.7 gone", "550 5.17.1 gone", "550 5.7.1234 gone"] do
        {verdict, _} = one(550, text)
        assert verdict.reason == "mailbox_unknown", text
      end
    end

    test "a policy text that merely says something does not exist is not a user-unknown text" do
      {verdict, _} = one(550, "reverse DNS for your IP does not exist, fixture block phrase")
      assert verdict.reason == "smtp_blocked"

      for text <- [
            "550 5.1.1 The email account does not exist",
            "550 The mailbox does not exist",
            "550 user does not exist here",
            "550 recipient does not exist",
            "550 account does not exist"
          ] do
        {verdict, _} = one(550, text)
        assert verdict.reason == "mailbox_unknown", text
      end
    end

    test "any IP address in the text is a block" do
      for text <- [
            "550 5.7.0 rejected: 203.0.113.9 is not allowed",
            "550 host [203.0.113.9] refused",
            "550 from 2001:db8::1 refused"
          ] do
        {verdict, result} = one(550, text)
        assert final(verdict) == {"not_sure", "smtp_blocked", "smtp", nil}, text
        assert result.domain.blocked
      end
    end

    test "things that look like numbers but are not an IP address are not a block" do
      for text <- ["550 5.1.2 bad address", "550 at 12:30:45 server time", "550 error 4.2.1"] do
        {verdict, _} = one(550, text)
        assert verdict.reason == "mailbox_unknown", text
      end
    end

    test "a user-unknown text is never a block, even with an IP address or a block phrase" do
      for text <- [
            "550 5.1.1 <a@b.ee>: user unknown (client 203.0.113.9)",
            "550 invalid recipient, see fixture block phrase",
            "550 5.1.1 relay fixture block other"
          ] do
        {verdict, result} = one(550, text)
        assert final(verdict) == {"invalid", "mailbox_unknown", "smtp", nil}, text
        refute result.domain.blocked
      end
    end

    test "an IP address does not turn into the 5.1.1 exception" do
      {verdict, _} = one(550, "550 refused for 5.1.1.9")
      assert verdict.reason == "smtp_blocked"
    end

    test "quota wins over block and an IP address, as in the original engine" do
      {verdict, _} = one(552, "fixture quota phrase for 203.0.113.9, fixture block phrase")
      assert verdict.reason == "mailbox_full"
    end

    test "a greylist phrase on a 5xx asks to retry; a user-unknown text still wins" do
      {verdict, result} = one(550, "Fixture grey phrase, please wait")
      assert %{action: :retry, kind: :grey} = verdict
      assert result.domain.grey_message == "Fixture grey phrase, please wait"

      {verdict, _} = one(550, "5.1.1 user unknown, fixture grey phrase")
      assert verdict.reason == "mailbox_unknown"
    end

    test "a code outside 2xx, 4xx is read like a 5xx" do
      {verdict, _} = one(0, "weird")
      assert verdict.reason == "mailbox_unknown"
    end
  end

  describe "RCPT deferred with a 4xx" do
    test "asks to retry, keeps the grey text on the domain, and is temp / greylisted at last" do
      {verdict, result} = one(451, "4.7.1 Fixture grey phrase, please wait")

      assert verdict.action == :retry
      assert verdict.kind == :grey

      assert verdict.exhausted == %{
               status: "temp",
               reason: "greylisted",
               level: "smtp",
               catch_all: nil
             }

      assert result.domain.grey_message == "4.7.1 Fixture grey phrase, please wait"
      refute result.domain.blocked
      refute result.failed
    end

    test "any other 4xx is treated the same" do
      {verdict, _} = one(452, "4.2.2 mailbox temporarily unavailable")
      assert %{action: :retry, kind: :grey} = verdict
    end

    test "a 4xx with an IP address in it is still a retry, not a block" do
      {verdict, _} = one(450, "450 4.7.1 client 203.0.113.9 not yet allowed")
      assert %{action: :retry, kind: :grey} = verdict
    end
  end

  describe "MAIL FROM" do
    test "a 5xx rejects the sender for every address: not_sure / mail_from_rejected" do
      steps = [@banner, @ehlo, %{cmd: "mail", code: 553, text: "5.7.1 sender rejected"}]
      result = classify(session([], steps: steps), ["a", "b"])

      for id <- ["a", "b"] do
        assert final(result.verdicts[id]) == {"not_sure", "mail_from_rejected", "smtp", nil}
      end

      refute result.domain.blocked
      refute result.failed
    end

    test "a 4xx defers every address like a greylist" do
      steps = [@banner, @ehlo, %{cmd: "mail", code: 450, text: "4.7.1 fixture grey phrase"}]
      result = classify(session([], steps: steps), ["a"])

      assert %{action: :retry, kind: :grey} = result.verdicts["a"]
      assert result.domain.grey_message == "4.7.1 fixture grey phrase"
    end
  end

  describe "banner and EHLO" do
    test "a 5xx banner blocks the session: not_sure / smtp_blocked for everyone" do
      steps = [%{cmd: "banner", code: 554, text: "no service for your address"}]
      result = classify(session([], steps: steps), ["a", "b"])

      for id <- ["a", "b"] do
        assert final(result.verdicts[id]) == {"not_sure", "smtp_blocked", "smtp", nil}
      end

      assert result.domain.blocked
      assert result.failed
    end

    test "a 5xx EHLO is a block too" do
      steps = [@banner, %{cmd: "ehlo", code: 550, text: "go away"}]
      result = classify(session([], steps: steps), ["a"])

      assert result.verdicts["a"].reason == "smtp_blocked"
      assert result.domain.blocked
    end

    test "a 4xx banner is a transient failure of the connection, not a failure of the runner" do
      steps = [%{cmd: "banner", code: 421, text: "too many connections"}]
      result = classify(session([], steps: steps), ["a"])

      assert %{action: :retry, kind: :transport} = result.verdicts["a"]
      assert result.verdicts["a"].exhausted.reason == "smtp_unavailable"
      refute result.failed
    end
  end

  describe "connection outcomes" do
    test "connect_failed retries and ends as not_sure / smtp_connect_failed; it counts against the runner" do
      result = classify(%{outcome: "connect_failed", steps: [], rcpt: []}, ["a"])

      assert %{action: :retry, kind: :transport} = result.verdicts["a"]

      assert result.verdicts["a"].exhausted ==
               %{status: "not_sure", reason: "smtp_connect_failed", level: "mx", catch_all: nil}

      assert result.failed
      refute result.domain.blocked
    end

    test "timeout and reset retry with their own final reason, and do not count against the runner" do
      for {outcome, reason} <- [{"timeout", "smtp_timeout"}, {"reset", "smtp_reset"}] do
        result = classify(%{outcome: outcome, steps: [@banner], rcpt: []}, ["a"])

        assert %{action: :retry, kind: :transport} = result.verdicts["a"]
        assert result.verdicts["a"].exhausted.reason == reason
        refute result.failed
      end
    end

    test "after a timeout the addresses answered before it keep their verdicts" do
      session =
        session([%{id: "a", code: 550, text: "5.1.1 user unknown"}], outcome: "timeout")

      result = classify(session, ["a", "b"])

      assert result.verdicts["a"].reason == "mailbox_unknown"
      assert %{action: :retry, kind: :transport} = result.verdicts["b"]
      assert result.verdicts["b"].exhausted.reason == "smtp_timeout"
    end

    test "an answered session with no reply for an address retries it as a reset" do
      result = classify(session([%{id: "a", code: 250, text: "ok"}]), ["a", "b"])

      assert result.verdicts["a"].reason == "smtp_ok"
      assert result.verdicts["b"].exhausted.reason == "smtp_reset"
    end
  end

  describe "a session with several addresses" do
    test "each address is judged on its own reply" do
      rcpt = [
        %{id: "ok", code: 250, text: "ok"},
        %{id: "gone", code: 550, text: "5.1.1 user unknown"},
        %{id: "full", code: 552, text: "fixture quota phrase"},
        %{id: "wait", code: 451, text: "fixture grey phrase"},
        %{id: "block", code: 554, text: "listed, fixture block phrase"}
      ]

      result = classify(session(rcpt), Enum.map(rcpt, & &1.id), catch_all: false)

      assert result.verdicts["ok"].reason == "smtp_ok"
      assert result.verdicts["gone"].reason == "mailbox_unknown"
      assert result.verdicts["full"].reason == "mailbox_full"
      assert %{action: :retry, kind: :grey} = result.verdicts["wait"]
      assert result.verdicts["block"].reason == "smtp_blocked"
      assert result.domain.blocked
      assert result.failed
      assert result.domain.grey_message == "fixture grey phrase"
    end

    test "the verdicts are exactly the ids asked about" do
      result = classify(session([%{id: "x", code: 250, text: "ok"}]), ["a"])
      assert Map.keys(result.verdicts) == ["a"]
    end
  end

  describe "phrases" do
    test "the default lists come from the dictionaries, with the shipped user-unknown list" do
      phrases = Classifier.phrases()

      assert Map.keys(phrases) |> Enum.sort() == [:block, :grey, :quota, :user_unknown]
      assert "user unknown" in phrases.user_unknown
      assert "mailbox does not exist" in phrases.user_unknown
      refute "does not exist" in phrases.user_unknown
      refute "mailbox unavailable" in phrases.user_unknown
      assert length(phrases.user_unknown) == 12
    end

    test "the shipped user-unknown list leaves a policy text alone" do
      {verdict, _} =
        one_with(Classifier.phrases(), 550, "5.7.1 reverse DNS for your IP does not exist")

      assert verdict.reason == "smtp_blocked"

      {verdict, _} = one_with(Classifier.phrases(), 550, "mailbox unavailable")
      assert verdict.reason == "mailbox_unknown"
    end

    test "with no block phrases loaded only an IP address blocks" do
      empty = %{grey: [], quota: [], block: [], user_unknown: ["5.1.1"]}

      {verdict, _} = one_with(empty, 550, "fixture block phrase")
      assert verdict.reason == "mailbox_unknown"

      {verdict, _} = one_with(empty, 550, "blocked at 203.0.113.9")
      assert verdict.reason == "smtp_blocked"
    end

    test "a phrase written with punctuation matches the normalised text" do
      phrases = %{grey: [], quota: [], block: ["x.y.z"], user_unknown: []}
      {verdict, _} = one_with(phrases, 550, "x.y.z rejected")
      assert verdict.reason == "smtp_blocked"
    end

    test "non-text replies are survived" do
      {verdict, _} = one(550, nil)
      assert verdict.reason == "mailbox_unknown"
    end

    defp one_with(phrases, code, text) do
      session = session([%{id: "a", code: code, text: text}])
      result = Classifier.classify(session, ["a"], phrases: phrases)
      {result.verdicts["a"], result}
    end
  end
end
