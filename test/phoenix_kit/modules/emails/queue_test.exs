defmodule PhoenixKit.Modules.Emails.QueueTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Queue
  alias Swoosh.Email

  # These cover the parts of the queue that are pure: the serialisation the
  # worker's send depends on, the opts allowlist, and the host-config check.
  # The decision matrix itself reads settings from the database and belongs in
  # an integration test.

  defp email do
    Email.new()
    |> Email.to([{"Ann", "ann@example.com"}, {"", "bob@example.com"}])
    |> Email.from({"Acme", "noreply@example.com"})
    |> Email.cc({"Cara", "cara@example.com"})
    |> Email.bcc({"", "audit@example.com"})
    |> Email.reply_to({"Support", "support@example.com"})
    |> Email.subject("Subject")
    |> Email.text_body("text")
    |> Email.html_body("<p>html</p>")
    |> Email.header("X-PhoenixKit-Log-Id", "019f-abc")
    |> Email.header("X-Custom", "keep me")
  end

  describe "serialize/deserialize" do
    test "round-trips everything a send needs" do
      round_tripped = email() |> Queue.serialize() |> Queue.deserialize()

      assert round_tripped.to == [{"Ann", "ann@example.com"}, {"", "bob@example.com"}]
      assert round_tripped.from == {"Acme", "noreply@example.com"}
      assert round_tripped.cc == [{"Cara", "cara@example.com"}]
      assert round_tripped.bcc == [{"", "audit@example.com"}]
      assert round_tripped.reply_to == {"Support", "support@example.com"}
      assert round_tripped.subject == "Subject"
      assert round_tripped.text_body == "text"
      assert round_tripped.html_body == "<p>html</p>"
    end

    test "carries the tracking header across the hop" do
      # Without this the worker's send would write a SECOND log row and leave
      # the first stuck at "queued" — the idempotency check keys on this header.
      round_tripped = email() |> Queue.serialize() |> Queue.deserialize()

      assert round_tripped.headers["X-PhoenixKit-Log-Id"] == "019f-abc"
      assert round_tripped.headers["X-Custom"] == "keep me"
    end

    test "the serialised form is JSON-safe (Oban stores args as jsonb)" do
      serialised = Queue.serialize(email())

      assert {:ok, json} = Jason.encode(serialised)
      assert {:ok, decoded} = Jason.decode(json)
      # Survives the encode/decode Oban puts it through.
      assert Queue.deserialize(decoded).to == [
               {"Ann", "ann@example.com"},
               {"", "bob@example.com"}
             ]
    end

    test "tolerates a message with only the minimum set" do
      minimal = Email.new() |> Email.to("solo@example.com") |> Email.subject("Hi")
      round_tripped = minimal |> Queue.serialize() |> Queue.deserialize()

      assert round_tripped.to == [{"", "solo@example.com"}]
      assert round_tripped.subject == "Hi"
      assert round_tripped.from == nil
      assert round_tripped.text_body == nil
    end

    test "drops attachments — those messages are never queued in the first place" do
      serialised = Queue.serialize(email())
      refute Map.has_key?(serialised, "attachments")
    end
  end

  describe "opts round trip" do
    test "keeps only the opts the send path reads" do
      opts = [
        campaign_id: "newsletter",
        template_name: "welcome",
        provider: "smtp",
        user_uuid: "019f-user",
        secret: "must not travel",
        queue: false
      ]

      serialised = Queue.serialize_opts_for_test(opts)

      assert serialised == %{
               "campaign_id" => "newsletter",
               "template_name" => "welcome",
               "provider" => "smtp",
               "user_uuid" => "019f-user"
             }

      assert Enum.sort(Queue.deserialize_opts(serialised)) ==
               Enum.sort(
                 campaign_id: "newsletter",
                 template_name: "welcome",
                 provider: "smtp",
                 user_uuid: "019f-user"
               )
    end

    test "ignores unknown keys on the way back, so job args cannot mint atoms" do
      assert Queue.deserialize_opts(%{"campaign_id" => "x", "not_an_opt" => "y"}) ==
               [campaign_id: "x"]

      assert Queue.deserialize_opts(%{"definitely_not_an_existing_atom_9d2f" => "y"}) == []
      assert Queue.deserialize_opts(nil) == []
    end
  end

  describe "runnable?/0" do
    test "is false unless the host declared an :emails Oban queue" do
      app = PhoenixKit.Config.get_parent_app()
      original = Application.get_env(app, Oban)

      on_exit(fn ->
        if original,
          do: Application.put_env(app, Oban, original),
          else: Application.delete_env(app, Oban)
      end)

      Application.put_env(app, Oban, queues: [default: 10])
      refute Queue.runnable?()

      Application.put_env(app, Oban, queues: [default: 10, emails: 5])
      assert Queue.runnable?()

      # A shape we do not understand reads as "cannot drain" — inline send, which
      # is the safe direction.
      Application.put_env(app, Oban, queues: %{emails: 5})
      refute Queue.runnable?()

      Application.delete_env(app, Oban)
      refute Queue.runnable?()
    end
  end

  describe "maybe_enqueue/2" do
    test "passes through anything that is not an email" do
      assert Queue.maybe_enqueue(:not_an_email, []) == :continue
    end
  end
end
