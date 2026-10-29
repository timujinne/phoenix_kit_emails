defmodule PhoenixKit.Modules.Emails.MigrationRemovedTablesTest do
  @moduledoc """
  The address verification tables were removed from this module. Against a real
  database that means two things, and both are pinned here:

    * a fresh install of the chain does not create them;
    * a database where an earlier release of the chain (V4/V5) already created
      them keeps the tables, their indexes and their rows through every `up`
      and `down` this chain can run.

  Both run in a scratch schema inside the test's own sandbox transaction, so the
  tables the shared test database may still carry in `public` from earlier runs
  neither hide a failure nor are touched, and the whole thing is rolled back.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.Repo

  @schema "removed_tables_scratch"

  @adopted ~w(
    phoenix_kit_email_logs
    phoenix_kit_email_events
    phoenix_kit_email_blocklist
    phoenix_kit_email_metrics
    phoenix_kit_email_orphaned_events
  )

  # What the V4/V5 releases of the chain left in a database, as they emitted it.
  # The chain no longer carries this DDL, so the test does.
  @legacy_tables [
    {"phoenix_kit_email_verifications",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verifications (
       "uuid" uuid DEFAULT #{@schema}.uuid_generate_v7() NOT NULL,
       "email" citext NOT NULL,
       "domain" character varying(255),
       "status" character varying(16) NOT NULL,
       "reason" character varying(64),
       "level" character varying(16),
       "catch_all" boolean,
       "free" boolean DEFAULT false NOT NULL,
       "role" boolean DEFAULT false NOT NULL,
       "disposable" boolean DEFAULT false NOT NULL,
       "fake" boolean DEFAULT false NOT NULL,
       "curse" boolean DEFAULT false NOT NULL,
       "typo" boolean DEFAULT false NOT NULL,
       "mx" character varying(255),
       "log" jsonb DEFAULT '[]'::jsonb NOT NULL,
       "attempts" integer DEFAULT 1 NOT NULL,
       "checked_at" timestamp with time zone,
       "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
       "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
       PRIMARY KEY ("uuid")
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verifications (email, status) VALUES ('Keep@Example.com', 'valid')"},
    {"phoenix_kit_email_verify_domains",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verify_domains (
       "domain" character varying(253) NOT NULL,
       "mx" jsonb,
       "has_mx" boolean,
       "mx_checked_at" timestamp with time zone,
       "catch_all" boolean,
       "catch_all_checked_at" timestamp with time zone,
       "grey_message" text,
       "grey_at" timestamp with time zone,
       "last_smtp_at" timestamp with time zone,
       "blocks" jsonb DEFAULT '{}'::jsonb NOT NULL,
       "paused_until" timestamp with time zone,
       PRIMARY KEY ("domain")
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verify_domains (domain, has_mx) VALUES ('example.com', true)"},
    {"phoenix_kit_email_verify_batches",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verify_batches (
       "uuid" uuid DEFAULT #{@schema}.uuid_generate_v7() NOT NULL,
       "source_type" character varying(32) NOT NULL,
       "source_ref" character varying(255),
       "title" character varying(255),
       "state" character varying(16) DEFAULT 'queued' NOT NULL,
       "total" integer DEFAULT 0 NOT NULL,
       "processed" integer DEFAULT 0 NOT NULL,
       "counts" jsonb DEFAULT '{}'::jsonb NOT NULL,
       "created_by_uuid" uuid,
       "started_at" timestamp with time zone,
       "finished_at" timestamp with time zone,
       "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
       "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
       "awaiting_smtp" integer DEFAULT 0 NOT NULL,
       PRIMARY KEY ("uuid")
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verify_batches (source_type, awaiting_smtp) VALUES ('manual', 3)"},
    {"phoenix_kit_email_verify_batch_items",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verify_batch_items (
       "uuid" uuid DEFAULT #{@schema}.uuid_generate_v7() NOT NULL,
       "batch_uuid" uuid NOT NULL,
       "email" citext NOT NULL,
       "state" character varying(16) DEFAULT 'pending' NOT NULL,
       "next_attempt_at" timestamp with time zone,
       "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
       "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
       PRIMARY KEY ("uuid"),
       CONSTRAINT fk_email_verify_batch_items_batch FOREIGN KEY ("batch_uuid")
         REFERENCES #{@schema}.phoenix_kit_email_verify_batches ("uuid") ON DELETE CASCADE
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verify_batch_items (batch_uuid, email, state) " <>
       "SELECT uuid, 'a@example.com', 'awaiting_smtp' FROM #{@schema}.phoenix_kit_email_verify_batches"},
    {"phoenix_kit_email_verify_smtp_queue",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verify_smtp_queue (
       "uuid" uuid DEFAULT #{@schema}.uuid_generate_v7() NOT NULL,
       "email" citext NOT NULL,
       "checked_as" character varying(320) NOT NULL,
       "domain" character varying(253) NOT NULL,
       "state" character varying(16) DEFAULT 'queued' NOT NULL,
       "attempts" integer DEFAULT 0 NOT NULL,
       "grey_attempts" integer DEFAULT 0 NOT NULL,
       "transport_attempts" integer DEFAULT 0 NOT NULL,
       "lease_expiries" integer DEFAULT 0 NOT NULL,
       "not_before" timestamp with time zone,
       "lease_token" character varying(64),
       "leased_by" character varying(64),
       "lease_expires_at" timestamp with time zone,
       "last_reason" character varying(64),
       "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
       "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
       PRIMARY KEY ("uuid")
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verify_smtp_queue (email, checked_as, domain) VALUES ('a@example.com', 'a@example.com', 'example.com')"},
    {"phoenix_kit_email_verify_runners",
     """
     CREATE TABLE #{@schema}.phoenix_kit_email_verify_runners (
       "uuid" uuid DEFAULT #{@schema}.uuid_generate_v7() NOT NULL,
       "api_key_uuid" uuid NOT NULL,
       "name" character varying(255),
       "version" character varying(32),
       "os" character varying(255),
       "public_ip" character varying(45),
       "helo_auto" character varying(255),
       "port25" character varying(16) DEFAULT 'unknown' NOT NULL,
       "port25_checked_at" timestamp with time zone,
       "last_seen_at" timestamp with time zone,
       "jobs_done" integer DEFAULT 0 NOT NULL,
       "last_error" text,
       "paused_until" timestamp with time zone,
       "pause_reason" character varying(255),
       "fail_streak" integer DEFAULT 0 NOT NULL,
       "fail_domains" jsonb DEFAULT '[]'::jsonb NOT NULL,
       "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
       "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
       PRIMARY KEY ("uuid")
     )
     """,
     "INSERT INTO #{@schema}.phoenix_kit_email_verify_runners (api_key_uuid, name) VALUES (#{@schema}.uuid_generate_v7(), 'runner')"}
  ]

  # The 13 indexes besides the six primary keys that the V4/V5 releases emitted, so
  # that a statement of the chain dropping or recreating any one of them shows.
  @legacy_indexes [
    "CREATE UNIQUE INDEX phoenix_kit_email_verifications_email_idx " <>
      "ON #{@schema}.phoenix_kit_email_verifications USING btree (email)",
    "CREATE INDEX phoenix_kit_email_verifications_status_idx " <>
      "ON #{@schema}.phoenix_kit_email_verifications USING btree (status)",
    "CREATE INDEX phoenix_kit_email_verifications_domain_idx " <>
      "ON #{@schema}.phoenix_kit_email_verifications USING btree (domain)",
    "CREATE INDEX phoenix_kit_email_verify_batches_source_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_batches USING btree (source_type, source_ref)",
    "CREATE INDEX phoenix_kit_email_verify_batches_state_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_batches USING btree (state)",
    "CREATE UNIQUE INDEX phoenix_kit_email_verify_batch_items_member_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_batch_items USING btree (batch_uuid, email)",
    "CREATE INDEX phoenix_kit_email_verify_batch_items_state_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_batch_items USING btree (batch_uuid, state)",
    "CREATE UNIQUE INDEX phoenix_kit_email_verify_smtp_queue_live_email_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_smtp_queue USING btree (email) " <>
      "WHERE state IN ('queued', 'leased')",
    "CREATE INDEX phoenix_kit_email_verify_smtp_queue_state_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_smtp_queue USING btree (state, not_before)",
    "CREATE INDEX phoenix_kit_email_verify_smtp_queue_domain_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_smtp_queue USING btree (domain, state)",
    "CREATE INDEX phoenix_kit_email_verify_smtp_queue_lease_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_smtp_queue USING btree (lease_token) " <>
      "WHERE lease_token IS NOT NULL",
    "CREATE UNIQUE INDEX phoenix_kit_email_verify_runners_key_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_runners USING btree (api_key_uuid)",
    "CREATE INDEX phoenix_kit_email_verify_batch_items_awaiting_idx " <>
      "ON #{@schema}.phoenix_kit_email_verify_batch_items USING btree (email) " <>
      "WHERE state = 'awaiting_smtp'"
  ]

  # What core leaves in every schema it migrates: the prefix-local uuid default
  # the adopted tables' DDL calls. The wrapper stands in for it in the scratch
  # schema, and `public` stays on the search path for `gin_trgm_ops`, which the
  # chain references unqualified (see the moduledoc's "Where this chain
  # deliberately differs from the manifest").
  setup do
    Repo.query!("CREATE SCHEMA #{@schema}")

    Repo.query!(
      "CREATE FUNCTION #{@schema}.uuid_generate_v7() RETURNS uuid LANGUAGE sql " <>
        "AS 'SELECT public.uuid_generate_v7()'"
    )

    Repo.query!("SET LOCAL search_path TO #{@schema}, public")
    :ok
  end

  defp run_chain(version \\ Migrations.current_version()) do
    for statement <- Migrations.up_statements(@schema, version), do: Repo.query!(statement)
  end

  defp tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = $1 ORDER BY table_name",
        [@schema]
      )

    List.flatten(rows)
  end

  # Name and definition, so an index that was dropped and rebuilt differently shows too.
  defp indexes do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 ORDER BY indexname",
        [@schema]
      )

    rows
  end

  defp index_names, do: Enum.map(indexes(), &hd/1)

  defp constraints do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.relname, con.conname, pg_get_constraintdef(con.oid) FROM pg_constraint con " <>
          "JOIN pg_class c ON c.oid = con.conrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = $1 ORDER BY 1, 2",
        [@schema]
      )

    rows
  end

  defp legacy_rows do
    Map.new(@legacy_tables, fn {table, _create, _insert} ->
      {table, Repo.query!("SELECT * FROM #{@schema}.#{table} ORDER BY 1").rows}
    end)
  end

  defp seed_legacy_tables do
    Repo.query!("CREATE EXTENSION IF NOT EXISTS citext SCHEMA public")

    for {_table, create, _insert} <- @legacy_tables, do: Repo.query!(create)
    for {_table, _create, insert} <- @legacy_tables, do: Repo.query!(insert)
    for index <- @legacy_indexes, do: Repo.query!(index)
  end

  test "a fresh install gets the adopted tables and none of the verification ones" do
    run_chain()

    assert tables() == Enum.sort(@adopted)
    refute Enum.any?(tables(), &String.contains?(&1, "verif"))
    refute Enum.any?(index_names(), &String.contains?(&1, "verif"))

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM information_schema.columns " <>
                 "WHERE table_schema = $1 AND column_name = 'awaiting_smtp'",
               [@schema]
             )
  end

  test "tables an earlier release created are left in place, rows included, by every version" do
    run_chain()
    seed_legacy_tables()

    before_tables = tables()
    before_indexes = indexes()
    before_constraints = constraints()
    before_rows = legacy_rows()

    for version <- 1..Migrations.current_version() do
      run_chain(version)

      assert tables() == before_tables, "up at version #{version} changed the tables"
      assert indexes() == before_indexes, "up at version #{version} changed the indexes"

      assert constraints() == before_constraints,
             "up at version #{version} changed the constraints"

      assert legacy_rows() == before_rows, "up at version #{version} changed verification data"
    end

    assert Repo.query!("SELECT awaiting_smtp FROM #{@schema}.phoenix_kit_email_verify_batches").rows ==
             [[3]]
  end

  test "down leaves them standing too" do
    run_chain()
    seed_legacy_tables()

    before_tables = tables()
    before_indexes = indexes()
    before_constraints = constraints()
    before_rows = legacy_rows()

    for target <- 0..Migrations.current_version() do
      for statement <- Migrations.down_statements(@schema, target), do: Repo.query!(statement)

      assert tables() == before_tables, "down to #{target} changed the tables"
      assert indexes() == before_indexes, "down to #{target} changed the indexes"
      assert constraints() == before_constraints, "down to #{target} changed the constraints"

      assert legacy_rows() == before_rows, "down to #{target} changed verification data"
    end
  end
end
