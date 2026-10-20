defmodule PhoenixKit.Modules.Emails.MigrationV4TablesTest do
  @moduledoc """
  V4 against a real database: the four verification tables exist with the expected
  columns, the constraints that matter hold, and replaying the chain
  changes nothing.
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

  test "every owned table exists" do
    for table <- Migrations.owned_tables() do
      assert map_size(columns(table)) > 0, "#{table} is missing"
    end
  end

  test "verifications has the expected columns, email as citext" do
    columns = columns("phoenix_kit_email_verifications")

    expected =
      ~w(uuid email domain status reason level catch_all free role disposable fake curse typo mx log attempts checked_at inserted_at updated_at)

    assert Map.keys(columns) |> Enum.sort() == Enum.sort(expected)
    assert {"citext", false} = columns["email"]
    assert {"jsonb", false} = columns["log"]
    assert {"bool", true} = columns["catch_all"]
    assert {"bool", false} = columns["fake"]
    assert {"bool", false} = columns["curse"]
    assert {"bool", false} = columns["typo"]
    assert {"timestamptz", true} = columns["checked_at"]
  end

  test "verify_domains has one timestamp per cached fact and the domain as key" do
    columns = columns("phoenix_kit_email_verify_domains")

    expected =
      ~w(domain mx has_mx mx_checked_at catch_all catch_all_checked_at grey_message grey_at last_smtp_at blocks paused_until)

    assert Map.keys(columns) |> Enum.sort() == Enum.sort(expected)
  end

  test "batches and batch items have the expected columns" do
    assert Map.keys(columns("phoenix_kit_email_verify_batches")) |> Enum.sort() ==
             Enum.sort(
               ~w(uuid source_type source_ref title state total processed counts created_by_uuid started_at finished_at inserted_at updated_at awaiting_smtp)
             )

    assert Map.keys(columns("phoenix_kit_email_verify_batch_items")) |> Enum.sort() ==
             Enum.sort(~w(uuid batch_uuid email state next_attempt_at inserted_at updated_at))
  end

  test "the address is unique case-insensitively" do
    insert = fn email ->
      Repo.query(
        "INSERT INTO phoenix_kit_email_verifications (email, status) VALUES ($1, 'valid')",
        [email]
      )
    end

    assert {:ok, _} = insert.("Dup@Example.com")

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert.("dup@example.COM")
  end

  test "defaults: a batch starts queued and empty, an item starts pending" do
    %{rows: [[batch_uuid, state, total, processed, counts]]} =
      Repo.query!(
        "INSERT INTO phoenix_kit_email_verify_batches (source_type) VALUES ('manual') " <>
          "RETURNING uuid, state, total, processed, counts"
      )

    assert {state, total, processed, counts} == {"queued", 0, 0, %{}}

    assert %{rows: [["pending"]]} =
             Repo.query!(
               "INSERT INTO phoenix_kit_email_verify_batch_items (batch_uuid, email) " <>
                 "VALUES ($1, 'a@example.com') RETURNING state",
               [batch_uuid]
             )
  end

  test "a batch member is unique per batch, and deleting the batch deletes its items" do
    %{rows: [[batch]]} =
      Repo.query!(
        "INSERT INTO phoenix_kit_email_verify_batches (source_type) VALUES ('manual') RETURNING uuid"
      )

    item = "INSERT INTO phoenix_kit_email_verify_batch_items (batch_uuid, email) VALUES ($1, $2)"
    Repo.query!(item, [batch, "a@example.com"])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(item, [batch, "A@EXAMPLE.COM"])

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(item, [Ecto.UUID.bingenerate(), "b@example.com"])

    Repo.query!("DELETE FROM phoenix_kit_email_verify_batches WHERE uuid = $1", [batch])

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM phoenix_kit_email_verify_batch_items WHERE batch_uuid = $1",
               [batch]
             )
  end

  test "replaying the chain is harmless and keeps the rows" do
    Repo.query!(
      "INSERT INTO phoenix_kit_email_verifications (email, status) VALUES ('keep@example.com', 'valid')"
    )

    for statement <- Migrations.up_statements(), do: Repo.query!(statement)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM phoenix_kit_email_verifications WHERE email = 'keep@example.com'"
             )
  end
end
