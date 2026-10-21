defmodule PhoenixKit.Modules.Emails.Verification.Smtp.DirectTest do
  @moduledoc """
  The SMTP session of the built-in runner against a fake mail host on 127.0.0.1 (ephemeral
  port, started here). Every scenario of the shared test vectors
  (`priv/smtp_runner/test_vectors.json`, the same file the PowerShell runner is tested
  with) is replayed and the report must equal the vector's: this is what proves that the
  two dialogues agree. The commands the fake host received must be the vector's, in order,
  and never `DATA`. Nothing connects to a real host.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Classifier
  alias PhoenixKit.Modules.Emails.Verification.Smtp.Direct
  alias PhoenixKitEmails.Test.FakeSmtpServer

  @path "priv/smtp_runner/test_vectors.json"
  @document @path |> File.read!() |> JSON.decode!()

  defp settings(vector) do
    base = @document["defaults"]["settings"] |> Map.merge(vector["settings"] || %{})

    %{
      mail_from: base["mail_from"],
      helo: base["helo"],
      connect_timeout_s: base["connect_timeout_s"],
      read_timeout_s: base["read_timeout_s"]
    }
  end

  defp session(vector) do
    defaults = @document["defaults"]

    %{
      lease: vector["report"]["lease"],
      domain: vector["domain"] || defaults["domain"],
      mx: vector["mx"] || defaults["mx"],
      probe: Map.get(vector, "probe", defaults["probe"]),
      rcpt: for(item <- vector["rcpt"], do: %{id: item["id"], email: item["email"]})
    }
  end

  defp without_ms(report), do: Map.delete(report, "ms")

  describe "the shared test vectors" do
    for vector <- @document["vectors"] do
      @vector vector

      test "#{vector["name"]}: the report and the commands are the vector's" do
        vector = @vector
        server = FakeSmtpServer.start(vector["smtp"])

        assert {:ok, report} = Direct.run(session(vector), settings(vector), port: server.port)

        assert without_ms(report) == vector["report"]
        assert is_integer(report["ms"]) and report["ms"] >= 0
        assert FakeSmtpServer.commands(server) == vector["commands"]
        refute Enum.any?(FakeSmtpServer.commands(server), &String.starts_with?(&1, "DATA"))
      end

      test "#{vector["name"]}: the classifier reads the report as the vector says" do
        vector = @vector
        server = FakeSmtpServer.start(vector["smtp"])
        {:ok, report} = Direct.run(session(vector), settings(vector), port: server.port)

        result = atomise(report)
        ids = Enum.map(vector["rcpt"], & &1["id"])
        phrases = %{Classifier.phrases() | grey: [], quota: [], block: []}

        classification = Classifier.classify(result, ids, phrases: phrases, catch_all: nil)

        assert classification.failed == vector["classification"]["failed"]

        for {id, expected} <- vector["classification"]["verdicts"] do
          verdict = classification.verdicts[id]
          assert Atom.to_string(verdict.action) == expected["action"], "#{id}"
        end
      end
    end
  end

  # The report as `SmtpQueue.report/4` parses it.
  defp atomise(report) do
    %{
      lease: report["lease"],
      outcome: report["outcome"],
      mx_used: report["mx_used"],
      ms: report["ms"],
      steps: for(s <- report["steps"], do: %{cmd: s["cmd"], code: s["code"], text: s["text"]}),
      rcpt: for(r <- report["rcpt"], do: %{id: r["id"], code: r["code"], text: r["text"]})
    }
  end

  @ok_spec %{
    "banner" => ["220 mx.example.test ESMTP ready"],
    "rules" => [
      %{"match" => "^EHLO ", "reply" => ["250 mx.example.test"]},
      %{"match" => "^MAIL FROM:", "reply" => ["250 2.1.0 Ok"]},
      %{"match" => "^RCPT TO:", "reply" => ["250 2.1.5 Ok"]},
      %{"match" => "^QUIT", "reply" => ["221 2.0.0 Bye"], "then" => "close"}
    ]
  }

  defp plain_session(extra \\ %{}) do
    Map.merge(
      %{
        lease: "lease-x",
        domain: "example.test",
        mx: ["127.0.0.1"],
        probe: nil,
        rcpt: [%{id: "r1", email: "info@example.test"}]
      },
      extra
    )
  end

  @sender %{mail_from: "verify@sender.test", helo: "runner.example.test"}

  describe "the sender and the greeting name" do
    test "without a MAIL FROM nothing is connected" do
      server = FakeSmtpServer.start(@ok_spec)

      for mail_from <- [nil, "", "no-at-sign", "a b@example.test", "x@y.test\r\nDATA"] do
        assert {:error, :no_mail_from} =
                 Direct.run(plain_session(), %{@sender | mail_from: mail_from}, port: server.port)
      end

      assert FakeSmtpServer.connections(server) == 0
    end

    test "EHLO carries the configured name, or localhost when it is missing or unusable" do
      for {helo, expected} <- [
            {"runner.example.test", "EHLO runner.example.test"},
            {nil, "EHLO localhost"},
            {"bad name\r\nDATA", "EHLO localhost"}
          ] do
        server = FakeSmtpServer.start(@ok_spec)
        {:ok, _} = Direct.run(plain_session(), %{@sender | helo: helo}, port: server.port)
        assert hd(FakeSmtpServer.commands(server)) == expected
      end
    end
  end

  describe "the dialogue" do
    test "an address that is not safe on a command line is not sent" do
      server = FakeSmtpServer.start(@ok_spec)

      session =
        plain_session(%{
          probe: "bad probe@example.test",
          rcpt: [
            %{id: "r1", email: "a@example.test>\r\nDATA"},
            %{id: "r2", email: "ok@example.test"}
          ]
        })

      {:ok, report} = Direct.run(session, @sender, port: server.port)

      assert [%{"id" => "r2"}] = report["rcpt"]

      assert FakeSmtpServer.commands(server) == [
               "EHLO runner.example.test",
               "MAIL FROM:<verify@sender.test>",
               "RCPT TO:<ok@example.test>",
               "QUIT"
             ]
    end

    test "a text over 512 characters is cut" do
      long = String.duplicate("x", 700)

      spec = %{
        @ok_spec
        | "rules" => [%{"match" => "^EHLO ", "reply" => ["250 " <> long]} | @ok_spec["rules"]]
      }

      server = FakeSmtpServer.start(spec)
      {:ok, report} = Direct.run(plain_session(), @sender, port: server.port)

      assert [_banner, %{"cmd" => "ehlo", "text" => text} | _] = report["steps"]
      assert String.length(text) == 512
    end

    test "a 421 to a recipient ends the session without QUIT" do
      spec = %{
        @ok_spec
        | "rules" => [
            %{"match" => "^RCPT TO:<b@", "reply" => ["421 4.7.0 Too many"]}
            | @ok_spec["rules"]
          ]
      }

      server = FakeSmtpServer.start(spec)

      session =
        plain_session(%{
          rcpt: for(l <- ~w(a b c), do: %{id: l, email: "#{l}@example.test"})
        })

      {:ok, report} = Direct.run(session, @sender, port: server.port)

      assert report["outcome"] == "answered"
      assert Enum.map(report["rcpt"], &{&1["id"], &1["code"]}) == [{"a", 250}, {"b", 421}]
      refute "QUIT" in FakeSmtpServer.commands(server)
      refute Enum.any?(FakeSmtpServer.commands(server), &(&1 =~ "c@example.test"))
    end

    test "a host without a usable banner is followed by the next one, two hosts at most" do
      refusing = FakeSmtpServer.start(%{"banner" => ["554 no service"], "banner_then" => "close"})

      # Only 127.0.0.1 listens: the second host (127.0.0.2) refuses the connection, and the
      # report is that of the last host tried, as in the runner script. The third is never
      # tried.
      {:ok, report} =
        Direct.run(plain_session(%{mx: ["127.0.0.1", "127.0.0.2", "127.0.0.3"]}), @sender,
          port: refusing.port
        )

      assert %{"mx_used" => "127.0.0.2", "outcome" => "connect_failed", "steps" => []} = report
      assert FakeSmtpServer.connections(refusing) == 1
    end

    test "a host that gave a 2xx banner is the last one asked, whatever it then says" do
      spec = %{
        @ok_spec
        | "rules" => [%{"match" => "^MAIL FROM:", "reply" => ["553 no"]} | @ok_spec["rules"]]
      }

      server = FakeSmtpServer.start(spec)

      {:ok, report} =
        Direct.run(plain_session(%{mx: ["127.0.0.1", "127.0.0.2"]}), @sender, port: server.port)

      assert report["mx_used"] == "127.0.0.1"
      assert [_, _, %{"cmd" => "mail", "code" => 553}] = report["steps"]
      assert FakeSmtpServer.connections(server) == 1
    end

    test "a reply that is not SMTP is a reset" do
      server = FakeSmtpServer.start(%{"banner" => ["hello there"], "rules" => []})
      {:ok, report} = Direct.run(plain_session(), @sender, port: server.port)

      assert report["outcome"] == "reset"
      assert report["steps"] == []
    end

    test "a reply of a hundred lines is a reset" do
      lines = for n <- 1..100, do: "250-line #{n}"

      spec = %{
        @ok_spec
        | "rules" => [%{"match" => "^EHLO ", "reply" => lines ++ ["250 end"]} | @ok_spec["rules"]]
      }

      server = FakeSmtpServer.start(spec)
      {:ok, report} = Direct.run(plain_session(), @sender, port: server.port)

      assert report["outcome"] == "reset"
      assert [%{"cmd" => "banner"}] = report["steps"]
    end

    test "a session with no mail hosts did not connect" do
      assert {:ok, report} = Direct.run(plain_session(%{mx: []}), @sender, port: 1)

      assert %{"outcome" => "connect_failed", "mx_used" => nil, "steps" => [], "rcpt" => []} =
               report
    end

    test "the whole session has a deadline" do
      spec = %{
        @ok_spec
        | "rules" => [
            %{"match" => "^RCPT TO:", "delay" => 2, "reply" => ["250 late"]} | @ok_spec["rules"]
          ]
      }

      server = FakeSmtpServer.start(spec)

      {:ok, report} =
        Direct.run(plain_session(), Map.put(@sender, :read_timeout_s, 30),
          port: server.port,
          hard_ms: 300
        )

      assert report["outcome"] == "timeout"
    end
  end

  describe "connect_budget/3" do
    test "a connect wait is cut to what is left of the session" do
      assert Direct.connect_budget(%{connect_ms: 1_000_000}, 10_000, 5_000) == {:ok, 5_000}
    end

    test "a connect wait shorter than what is left stays as it is" do
      assert Direct.connect_budget(%{connect_ms: 20_000}, 100_000, 5_000) == {:ok, 20_000}
    end

    test "nothing is left once the session limit has passed" do
      assert Direct.connect_budget(%{connect_ms: 20_000}, 5_000, 5_000) == :expired
      assert Direct.connect_budget(%{connect_ms: 20_000}, 4_000, 5_000) == :expired
    end

    test "a session past its limit connects to no host" do
      server = FakeSmtpServer.start(@ok_spec)

      {:ok, report} = Direct.run(plain_session(), @sender, port: server.port, hard_ms: 0)

      assert %{"outcome" => "connect_failed", "steps" => []} = report
    end
  end

  describe "where it may connect" do
    test "the test config allows the loopback interface only" do
      assert Application.get_env(:phoenix_kit_emails, :verification_smtp_loopback_only) == true

      # Raised before any connection is made.
      assert_raise ArgumentError, ~r/refusing to connect/, fn ->
        Direct.run(plain_session(%{mx: ["192.0.2.55"]}), @sender, port: 1)
      end

      assert_raise ArgumentError, ~r/refusing to connect/, fn ->
        Direct.run(plain_session(%{mx: ["mx.example.com"]}), @sender, port: 1)
      end

      assert_raise ArgumentError, ~r/refusing to connect/, fn ->
        Direct.check_port("mx.example.com", %{}, port: 1)
      end
    end

    test "without a port the configured one is used, never a real mail port by accident" do
      assert Application.get_env(:phoenix_kit_emails, :verification_smtp_port) == 1
      assert {:ok, %{"outcome" => "connect_failed"}} = Direct.run(plain_session(), @sender)
    end
  end

  describe "check_port/3" do
    test "a 220 banner is open, and the check says QUIT" do
      server = FakeSmtpServer.start(@ok_spec)

      assert %{state: "open", banner: "220 mx.example.test ESMTP ready"} =
               Direct.check_port("127.0.0.1", %{}, port: server.port)

      assert FakeSmtpServer.commands(server) == ["QUIT"]
    end

    test "no connection is blocked" do
      assert %{state: "blocked"} =
               Direct.check_port("127.0.0.1", %{}, port: FakeSmtpServer.closed_port())
    end

    test "another banner is unknown" do
      server = FakeSmtpServer.start(%{"banner" => ["421 busy"], "banner_then" => "close"})

      assert %{state: "unknown", banner: "421 busy"} =
               Direct.check_port("127.0.0.1", %{}, port: server.port)

      assert FakeSmtpServer.commands(server) == []
    end

    test "a host that says nothing is unknown after the read timeout" do
      server = FakeSmtpServer.start(%{"banner" => nil, "rules" => []})

      assert %{state: "unknown", detail: "timeout"} =
               Direct.check_port("127.0.0.1", %{read_timeout_s: 1}, port: server.port)
    end
  end
end
