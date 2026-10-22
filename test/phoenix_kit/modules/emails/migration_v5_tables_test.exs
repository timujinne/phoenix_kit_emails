defmodule PhoenixKit.Modules.Emails.MigrationV5TablesTest do
  @moduledoc """
  V5 against a real database: the SMTP queue and the runners have the expected
  columns, the unique partial index lets an address wait once and be
  queued again after it finished, and replaying the chain keeps the rows.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.Repo

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, udt_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1",
        [table]
      )

    Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable == "YES"}} end)
  end

  defp enqueue(email, state \\ "queued") do
    Repo.query(
      "INSERT INTO phoenix_kit_email_verify_smtp_queue (email, checked_as, domain, state) " <>
        "VALUES ($1, $2, 'example.ee', $3)",
      [email, email, state]
    )
  end

  test "the database is stamped at the current version" do
    assert Migrations.migrated_version_runtime() == Migrations.current_version()
    assert Migrations.current_version() >= 5
  end

  test "the queue has the expected columns, the address as citext" do
    columns = columns("phoenix_kit_email_verify_smtp_queue")

    expected =
      ~w(uuid email checked_as domain state attempts grey_attempts transport_attempts lease_expiries not_before lease_token leased_by lease_expires_at last_reason inserted_at updated_at)

    assert Map.keys(columns) |> Enum.sort() == Enum.sort(expected)
    assert {"citext", false} = columns["email"]
    assert {"timestamptz", true} = columns["not_before"]
    assert {"timestamptz", true} = columns["lease_expires_at"]
  end

  test "the runners table has the expected columns and the autopause state" do
    columns = columns("phoenix_kit_email_verify_runners")

    expected =
      ~w(uuid api_key_uuid name version os public_ip helo_auto port25 port25_checked_at last_seen_at jobs_done last_error paused_until pause_reason fail_streak fail_domains inserted_at updated_at)

    assert Map.keys(columns) |> Enum.sort() == Enum.sort(expected)
    assert {"uuid", false} = columns["api_key_uuid"]
  end

  test "the queue's defaults: queued, no attempts" do
    assert {:ok, _} = enqueue("a@example.ee")

    assert %{rows: [["queued", 0, 0, 0, 0]]} =
             Repo.query!(
               "SELECT state, attempts, grey_attempts, transport_attempts, lease_expiries " <>
                 "FROM phoenix_kit_email_verify_smtp_queue"
             )
  end

  test "a live address is queued once, whatever its case" do
    assert {:ok, _} = enqueue("Dup@Example.ee")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             enqueue("dup@example.EE")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             enqueue("dup@example.ee", "leased")
  end

  test "a finished or cancelled address can be queued again" do
    for state <- ["done", "cancelled"] do
      email = "#{state}@example.ee"
      assert {:ok, _} = enqueue(email, state)
      assert {:ok, _} = enqueue(email, "queued")
    end

    assert {:ok, _} = enqueue("twice@example.ee", "done")
    assert {:ok, _} = enqueue("twice@example.ee", "done")
  end

  test "one runner per API key" do
    key = Ecto.UUID.generate()
    sql = "INSERT INTO phoenix_kit_email_verify_runners (api_key_uuid) VALUES ($1)"

    Repo.query!(sql, [Ecto.UUID.dump!(key)])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, [Ecto.UUID.dump!(key)])

    assert %{rows: [["unknown", 0, 0]]} =
             Repo.query!(
               "SELECT port25, jobs_done, fail_streak FROM phoenix_kit_email_verify_runners"
             )
  end

  test "a batch starts with nothing awaiting SMTP" do
    assert %{rows: [[0]]} =
             Repo.query!(
               "INSERT INTO phoenix_kit_email_verify_batches (source_type) VALUES ('manual') " <>
                 "RETURNING awaiting_smtp"
             )
  end

  test "replaying the chain keeps the queue rows" do
    {:ok, _} = enqueue("keep@example.ee")

    for statement <- Migrations.up_statements(), do: Repo.query!(statement)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM phoenix_kit_email_verify_smtp_queue WHERE email = 'keep@example.ee'"
             )
  end
end
