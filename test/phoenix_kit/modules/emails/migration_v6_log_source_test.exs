defmodule PhoenixKit.Modules.Emails.MigrationV6LogSourceTest do
  @moduledoc """
  V6 against a real database: `template_uuid` and `template_source` on the log
  (#48), both nullable, idempotent on replay, and a rollback that only moves
  the marker (this chain never drops a column).
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.Repo

  @table "phoenix_kit_email_logs"

  defp column(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT udt_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [@table, name]
      )

    rows
  end

  test "the chain is at version 6 and the database is stamped with it" do
    assert Migrations.current_version() == 6
    assert Migrations.migrated_version_runtime() == 6
  end

  test "the log has the two nullable columns" do
    assert [["uuid", "YES"]] = column("template_uuid")
    assert [["varchar", "YES"]] = column("template_source")
  end

  test "up at V6 adds them, and a pinned V5 does not" do
    added = fn version ->
      Migrations.up_statements("public", version)
      |> Enum.filter(&(&1 =~ "template_uuid" or &1 =~ "template_source"))
    end

    assert [uuid, source] = added.(6)
    assert uuid =~ ~s(ADD COLUMN IF NOT EXISTS "template_uuid" uuid)
    assert source =~ ~s[ADD COLUMN IF NOT EXISTS "template_source" character varying(16)]
    assert added.(5) == []
  end

  test "replaying the chain is idempotent and keeps the data" do
    Repo.query!(
      ~s[INSERT INTO #{@table} (message_id, "to", "from", template_source, inserted_at, updated_at) ] <>
        "VALUES ('v6-keep', 'a@example.com', 'b@example.com', 'file', now(), now())"
    )

    for statement <- Migrations.up_statements(), do: Repo.query!(statement)

    assert %{rows: [["file"]]} =
             Repo.query!("SELECT template_source FROM #{@table} WHERE message_id = 'v6-keep'")
  end

  test "down to V5 only moves the marker" do
    assert Migrations.down_statements("public", 5) == [
             "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:5'"
           ]

    refute Enum.any?(Migrations.down_statements("public", 5), &(&1 =~ ~r/DROP/i))
  end

  test "down really rolls the marker back, and up brings it forward again" do
    Migrations.down_statements("public", 5) |> Enum.each(&Repo.query!/1)

    try do
      assert Migrations.migrated_version_runtime() == 5
      assert [["uuid", "YES"]] = column("template_uuid")
    after
      Migrations.up_statements() |> Enum.each(&Repo.query!/1)
    end

    assert Migrations.migrated_version_runtime() == 6
  end
end
