defmodule PhoenixKit.Modules.Emails.MigrationsTest do
  @moduledoc """
  Ownership contract for this package's migration chain. `up_statements/1`
  and `down_statements/2` are the testable data form of what `up/1` and
  `down/1` execute, so most of this runs without a database.

  Two things it exists to pin:

    * **Nothing here can destroy data.** These tables are core-created on
      every install that exists today and hold the delivery history, so no
      statement this module can emit may contain `DROP` — the exact trap
      `phoenix_kit_legal`'s own chain documents having been one repaired
      version marker away from springing.
    * **The adopted DDL does not drift from core's.** V1 is an adoption
      step (see the module's moduledoc): every adopted statement must be
      byte-identical to what core's `ExpectedSchema` manifest declares for
      the same object, or a fresh install would end up with a shape core's
      auditor calls drifted.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Modules.Emails.Migrations

  @adopted_tables ~w(
    phoenix_kit_email_logs
    phoenix_kit_email_events
    phoenix_kit_email_blocklist
    phoenix_kit_email_templates
    phoenix_kit_email_metrics
    phoenix_kit_email_orphaned_events
  )

  # What the manifest declares for those tables, per class. Pinned exactly
  # rather than as a lower bound: a filter that quietly stops matching (a
  # renamed id format, a class that starts arriving differently) would leave a
  # conformance test that passes because it compares almost nothing. If core
  # legitimately adds an object, this fails, someone looks, and the number
  # moves deliberately.
  @manifest_object_counts %{table: 6, column: 96, constraint: 7, index: 52}

  # Statements this chain deliberately does NOT copy byte-for-byte from the
  # manifest, keyed by manifest object id, with the reason. Every departure
  # must be listed here; the tests below fail both on an unlisted departure
  # and on a listed one that no longer applies, so this map cannot rot in
  # either direction. See the module's "Where this chain deliberately differs
  # from the manifest".
  @declared_departures %{
    "table:phoenix_kit_email_logs" => "full column list, not the bare repair-form CREATE TABLE",
    "table:phoenix_kit_email_events" => "full column list",
    "table:phoenix_kit_email_blocklist" => "full column list",
    "table:phoenix_kit_email_templates" => "full column list",
    "table:phoenix_kit_email_metrics" => "full column list",
    "table:phoenix_kit_email_orphaned_events" => "full column list",
    "constraint:phoenix_kit_email_logs.phoenix_kit_email_logs_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_events.phoenix_kit_email_events_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_blocklist.phoenix_kit_email_blocklist_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_templates.phoenix_kit_email_templates_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_metrics.phoenix_kit_email_metrics_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_orphaned_events.phoenix_kit_email_orphaned_events_pkey" =>
      "probed by contype, not conname",
    "constraint:phoenix_kit_email_events.fk_email_events_email_log_uuid" => "added NOT VALID",
    "index:phoenix_kit_email_logs_subject_trgm_index" => "unqualified gin_trgm_ops",
    "index:phoenix_kit_email_logs_campaign_id_trgm_index" => "unqualified gin_trgm_ops",
    "index:phoenix_kit_email_logs_to_trgm_index" => "unqualified gin_trgm_ops"
  }

  describe "chain protocol" do
    test "current_version/0 is a positive integer and the marker table is the logs table" do
      assert is_integer(Migrations.current_version())
      assert Migrations.current_version() > 0
      assert Migrations.version_table() == "phoenix_kit_email_logs"
    end

    test "up stamps the version marker" do
      assert Enum.any?(
               Migrations.up_statements(),
               &(&1 ==
                   "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:#{Migrations.current_version()}'")
             )
    end

    test "down rewrites the marker, and below V3 hands raw-HTML placeholders back" do
      assert [rewrite, "COMMENT ON TABLE public.phoenix_kit_email_logs IS NULL"] =
               Migrations.down_statements("public", 0)

      assert rewrite =~ "UPDATE public.phoenix_kit_email_templates SET html_body"

      assert [rewrite, "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:1'"] =
               Migrations.down_statements("public", 1)

      assert rewrite =~ "UPDATE public.phoenix_kit_email_templates SET html_body"

      assert Migrations.down_statements("public", 3) == [
               "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:3'"
             ]
    end

    test "the schema prefix is validated before it reaches the DDL" do
      assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP TABLE x") end
      assert_raise ArgumentError, fn -> Migrations.down_statements("public; DROP TABLE x") end
    end
  end

  describe "adoption" do
    test "every table this package owns is created" do
      for table <- @adopted_tables do
        assert create_table_statement(table),
               "no CREATE TABLE for #{table}"
      end

      assert Enum.sort(Migrations.adopted_tables()) == Enum.sort(@adopted_tables)
    end

    test "CREATE TABLE carries core's full column list, NOT NULLs included" do
      # The regression this pins: building the table from the manifest's
      # repair DDL alone (`CREATE TABLE ... ()` + `ADD COLUMN IF NOT
      # EXISTS`) silently drops NOT NULL from every column without a
      # default — 26 of them — because adding such a column to a populated
      # table is impossible. A fresh install must still get core's shape.
      %{columns: columns} = Migrations.adopted_objects()

      for table <- @adopted_tables do
        statement = create_table_statement(table)
        table_columns = Enum.filter(columns, fn {t, _pos, _def, _nn} -> t == table end)

        assert table_columns != []

        for {_t, _pos, raw_definition, not_null} <- table_columns do
          # adopted_objects/0 is the RAW data, still carrying core's
          # `__SCHEMA__` token; up_statements/1 has resolved it.
          definition = String.replace(raw_definition, "__SCHEMA__", "public")

          assert String.contains?(statement, definition),
                 "#{table} is missing column #{definition}"

          if not_null do
            expected =
              if String.ends_with?(definition, " NOT NULL"),
                do: definition,
                else: definition <> " NOT NULL"

            assert String.contains?(statement, expected),
                   "#{table}.#{definition} lost its NOT NULL"
          end
        end
      end
    end

    test "our own columns are added on top of the table, not folded into it" do
      # CREATE TABLE is "the table core would have created"; everything this
      # chain adds is a separate, additive statement.
      refute String.contains?(
               create_table_statement("phoenix_kit_email_logs"),
               "integration_uuid"
             )
    end

    test "phoenix_kit_email_send_profiles is NOT adopted — core owns and uses it" do
      refute "phoenix_kit_email_send_profiles" in Migrations.adopted_tables()

      refute Enum.any?(
               Migrations.up_statements(),
               &String.contains?(&1, "phoenix_kit_email_send_profiles")
             )
    end

    test "each adopted table gets its uuid column, primary key and unique uuid index" do
      statements = Migrations.up_statements()

      for table <- @adopted_tables do
        assert Enum.any?(
                 statements,
                 &(&1 ==
                     "ALTER TABLE public.#{table} ADD COLUMN IF NOT EXISTS " <>
                       "\"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL")
               ),
               "no uuid column for #{table}"

        assert Enum.any?(statements, fn statement ->
                 String.contains?(statement, "ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid)")
               end),
               "no primary key for #{table}"
      end
    end

    test "indexes are emitted BEFORE constraints" do
      # A foreign key needs a unique index (or a primary key) on the columns it
      # references, and the primary key it would lean on is exactly what the
      # type guard skips on a drifted database. With the unique uuid index
      # already created, the foreign key survives a table whose primary key
      # could not be added.
      statements = Migrations.up_statements()

      last_index = last_index_matching(statements, &String.contains?(&1, "CREATE INDEX"))
      first_constraint = Enum.find_index(statements, &String.contains?(&1, "ADD CONSTRAINT"))

      assert last_index < first_constraint
    end

    test "the events -> logs foreign key is emitted after both primary keys" do
      statements = Migrations.up_statements()

      fk_index =
        Enum.find_index(statements, &String.contains?(&1, "fk_email_events_email_log_uuid"))

      logs_pkey_index =
        Enum.find_index(
          statements,
          &String.contains?(&1, "ADD CONSTRAINT phoenix_kit_email_logs_pkey")
        )

      assert is_integer(fk_index) and is_integer(logs_pkey_index)

      # The FK references phoenix_kit_email_logs(uuid), which needs the
      # primary key to already exist.
      assert logs_pkey_index < fk_index
    end

    test "the healing ADD COLUMN statements come after their table is created" do
      statements = Migrations.up_statements()

      for table <- @adopted_tables do
        create_index =
          Enum.find_index(
            statements,
            &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
          )

        first_column_index =
          Enum.find_index(
            statements,
            &String.starts_with?(&1, "ALTER TABLE public.#{table} ADD COLUMN")
          )

        assert create_index < first_column_index, "columns precede CREATE TABLE for #{table}"
      end
    end

    test "V1's own shape change: the integration_uuid column and its index" do
      statements = Migrations.up_statements()

      assert "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"integration_uuid\" uuid" in statements

      assert Enum.any?(
               statements,
               &String.contains?(&1, "phoenix_kit_email_logs_integration_uuid_idx")
             )
    end
  end

  describe "safety" do
    test "nothing this chain emits can drop a table or a column" do
      statements = Migrations.up_statements() ++ Migrations.down_statements()

      for statement <- statements do
        refute statement =~ ~r/\bDROP\b/i, "destructive statement: #{statement}"
      end
    end

    test "every statement is idempotent" do
      for statement <- Migrations.up_statements() do
        assert statement =~ "IF NOT EXISTS" or statement =~ "COMMENT ON" or
                 statement =~ "SET lock_timeout" or statement =~ "RESET lock_timeout" or
                 raw_html_rewrite?(statement) or
                 (statement =~ "DO $$" and
                    (statement =~ "EXISTS (" or statement =~ "VALIDATE CONSTRAINT")),
               "non-idempotent statement: #{statement}"
      end
    end

    test "no statement can abort the host's migration" do
      # The point of the whole guard layer: a drifted database must degrade to
      # a NOTICE, not take every other statement in the transaction down with
      # it. Proven end to end against a genuinely drifted database by
      # `dev_docs/verify/drift_replay.exs`; asserted here so the mechanism
      # cannot be removed without a test failing.
      for statement <- Migrations.up_statements(),
          statement =~ "ADD CONSTRAINT" or statement =~ "CREATE INDEX" or
            statement =~ "CREATE UNIQUE INDEX" or statement =~ "VALIDATE CONSTRAINT" do
        assert statement =~ "EXCEPTION",
               "this can abort the host's migration on a drifted database: #{statement}"
      end
    end

    test "constraints check the actual column TYPES before they are added" do
      # `ADD COLUMN IF NOT EXISTS` matches on name alone, so a column that
      # drifted to varchar (core's V163 documents exactly that) is "already
      # there" and stays wrong — and the constraint that follows then fails at
      # ADD time on the type mismatch, which NOT VALID does nothing about.
      for statement <- Migrations.up_statements(), statement =~ "ADD CONSTRAINT" do
        assert statement =~ "pg_attribute",
               "constraint added without checking column types: #{statement}"

        assert statement =~ "atttypid = 'uuid'::regtype"
      end
    end

    test "a foreign key checks the type on BOTH sides" do
      statement =
        Enum.find(
          Migrations.up_statements(),
          &String.contains?(&1, "ADD CONSTRAINT fk_email_events_email_log_uuid")
        )

      assert statement =~ "to_regclass('public.phoenix_kit_email_events')"
      assert statement =~ "to_regclass('public.phoenix_kit_email_logs')"
      assert statement =~ "a.attname = 'email_log_uuid'"
      assert statement =~ "a.attname = 'uuid'"
    end

    test "the chain opens by bounding how long it will wait for a lock" do
      # Postgres takes the lock BEFORE evaluating IF NOT EXISTS, so a
      # no-op migration can still queue every query on phoenix_kit_email_logs
      # behind one long-running reader. Failing in seconds beats hanging.
      assert [first | _] = Migrations.up_statements()
      assert first =~ ~r/^SET lock_timeout = '\d+s'$/

      # Session-scoped rather than SET LOCAL, because SET LOCAL is a silent
      # no-op outside a transaction and @disable_ddl_transaction is a
      # supported way to run this. Session scope has to be handed back.
      assert List.last(Migrations.up_statements()) == "RESET lock_timeout"
    end

    test "primary keys are probed by contype, so a differently-named PK is not re-added" do
      # A name-based probe passes on a table whose PK exists under another
      # name, and the ALTER then fails with "multiple primary keys for table
      # are not allowed" — aborting the host's whole migration.
      for statement <- Migrations.up_statements(),
          statement =~ "ADD CONSTRAINT" and statement =~ "PRIMARY KEY" do
        assert statement =~ "c.contype = 'p'",
               "primary key guarded by name rather than by contype: #{statement}"

        refute statement =~ ~r/c\.conname = '\w+_pkey'/
      end
    end

    test "the foreign key is added NOT VALID" do
      # phoenix_kit.doctor ships a check for orphaned
      # phoenix_kit_email_events.email_log_uuid rows, which means they exist in
      # the wild — and validating against them aborts the migration.
      statement =
        Enum.find(
          Migrations.up_statements(),
          &String.contains?(&1, "fk_email_events_email_log_uuid")
        )

      assert statement =~ "FOREIGN KEY"
      assert statement =~ "NOT VALID"
    end

    test "the foreign key IS validated, but only when that is free" do
      # NOT VALID is right for a populated table and wrong for an empty one:
      # a fresh install would otherwise carry a permanently-unvalidated FK
      # that core's name-based catalog probe never flags.
      statement =
        Enum.find(
          Migrations.up_statements(),
          &String.contains?(&1, "VALIDATE CONSTRAINT fk_email_events_email_log_uuid")
        )

      assert statement, "the FK is never validated, not even on an empty table"

      # Guarded on emptiness, so a populated table pays no scan and cannot fail.
      assert statement =~ "NOT EXISTS (SELECT 1 FROM public.phoenix_kit_email_events LIMIT 1)"

      # ...and even then it cannot take the host's migration down with it.
      assert statement =~ "EXCEPTION"

      # It has to come after the ADD, or there is nothing to validate.
      statements = Migrations.up_statements()
      add_index = Enum.find_index(statements, &String.contains?(&1, "ADD CONSTRAINT fk_email"))
      validate_index = Enum.find_index(statements, &String.contains?(&1, "VALIDATE CONSTRAINT"))
      assert add_index < validate_index
    end

    test "constraint probes tolerate a missing table instead of raising" do
      for statement <- Migrations.up_statements(), statement =~ "ADD CONSTRAINT" do
        assert statement =~ "to_regclass(",
               "a regclass cast would raise mid-transaction on a missing table: #{statement}"
      end
    end

    test "the trigram operator class is left unqualified" do
      trgm = Enum.filter(Migrations.up_statements(), &String.contains?(&1, "gin_trgm_ops"))

      assert length(trgm) == 3

      for statement <- trgm do
        refute statement =~ ~r/\w+\.gin_trgm_ops/,
               "a schema-qualified operator class breaks any install whose " <>
                 "pg_trgm is not in that schema: #{statement}"
      end
    end

    test "up_statements/1 is pure — repeated calls produce the identical list" do
      assert Migrations.up_statements() == Migrations.up_statements()
    end

    test "a custom prefix is applied to every reference to one of our tables" do
      for statement <- Migrations.up_statements("tenant_a") do
        refute statement =~ ~r/\bpublic\.phoenix_kit_email/,
               "statement leaked the public schema: #{statement}"
      end

      # ...and to the schema-qualified helpers our own DDL calls.
      refute Enum.any?(
               Migrations.up_statements("tenant_a"),
               &String.contains?(&1, "public.uuid_generate_v7()")
             )

      # The operator class is unqualified, so there is no schema to leak in
      # the first place — see "the trigram operator class is left
      # unqualified" above for why it is not `public.`-prefixed either.
      assert Enum.any?(
               Migrations.up_statements("tenant_a"),
               &String.contains?(&1, "gin_trgm_ops")
             )
    end

    test "the prefix-embedded index name is resolved, not left as a marker" do
      # Core embeds the prefix in a handful of index NAMES (bare on public,
      # "<prefix>_" elsewhere). Emitting the raw marker would create a
      # second, differently-named index on every non-public install.
      for prefix <- ["public", "tenant_a"] do
        refute Enum.any?(
                 Migrations.up_statements(prefix),
                 &String.contains?(&1, "__PK_NAME_EXEMPT__")
               )
      end

      assert Enum.any?(
               Migrations.up_statements("public"),
               &(&1 =~ ~r/CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_templates_uuid_idx /)
             )

      assert Enum.any?(
               Migrations.up_statements("tenant_a"),
               &(&1 =~
                   ~r/CREATE UNIQUE INDEX IF NOT EXISTS tenant_a_phoenix_kit_email_templates_uuid_idx /)
             )
    end
  end

  describe "conformance with core's ExpectedSchema manifest" do
    # V1 adopts core-created objects, so the adopted statements must match
    # what core itself would emit — byte for byte, for any prefix. This is
    # what stops the drift class that gave phoenix_kit_legal three
    # disagreeing DDL copies of one table.
    #
    # Deliberately SKIPS objects the manifest no longer declares: the whole
    # point of this chain is that a future core release stops shipping
    # them, and that release must not be blocked by its own success. What
    # is asserted is "for every adopted object core still knows about, we
    # agree with core".

    setup do
      unless Code.ensure_loaded?(ExpectedSchema) do
        raise "core's ExpectedSchema is unavailable — this test needs it"
      end

      :ok
    end

    test "the manifest still declares exactly the objects this chain was built from" do
      counts =
        ExpectedSchema.objects("public")
        |> Enum.filter(&adopted_object?/1)
        |> Enum.frequencies_by(& &1.class)

      assert counts == @manifest_object_counts
    end

    for prefix <- ["public", "tenant_a"] do
      test "adopted statements match core's manifest under prefix #{prefix}" do
        prefix = unquote(prefix)
        ours = MapSet.new(Migrations.up_statements(prefix))

        core_objects =
          ExpectedSchema.objects(prefix)
          |> Enum.filter(&(is_binary(&1.create) and adopted_object?(&1)))

        assert Enum.frequencies_by(core_objects, & &1.class) == @manifest_object_counts

        # Containment, not equality: index DDL is now WRAPPED in a soft-failure
        # guard (see `index_statements/0`), so core's statement appears inside
        # ours character for character rather than as the whole string. That is
        # a stronger check than it looks — a rewritten index would not be found.
        mismatched =
          core_objects
          |> Enum.reject(fn object ->
            MapSet.member?(ours, object.create) or
              Enum.any?(ours, &String.contains?(&1, object.create))
          end)
          |> Enum.map(& &1.id)

        undeclared = mismatched -- Map.keys(@declared_departures)

        assert undeclared == [],
               "these core objects are neither emitted byte-identically nor declared as " <>
                 "departures: #{inspect(undeclared)}"

        # ...and the other direction: a departure that no longer departs is a
        # stale exemption weakening the test, so it has to be removed.
        stale = Map.keys(@declared_departures) -- mismatched

        assert stale == [],
               "these departures are no longer departures and should be deleted " <>
                 "from @declared_departures: #{inspect(stale)}"
      end
    end

    test "every declared departure still emits SOMETHING for its object" do
      # A departure is "we write this differently", never "we skip this".
      statements = Migrations.up_statements()

      for {id, reason} <- @declared_departures do
        object_name = id |> String.split(":") |> List.last() |> String.split(".") |> List.last()

        assert Enum.any?(statements, &String.contains?(&1, object_name)),
               "#{id} is declared as a departure (#{reason}) but nothing is emitted for it"
      end
    end

    test "the only statements we emit beyond core's manifest are our own" do
      core =
        ExpectedSchema.objects("public")
        |> Enum.filter(&is_binary(&1.create))
        |> MapSet.new(& &1.create)

      departure_shapes = ["CREATE TABLE IF NOT EXISTS", "DO $$", "gin_trgm_ops"]

      extra =
        Enum.reject(
          Migrations.up_statements(),
          fn statement ->
            MapSet.member?(core, statement) or
              String.starts_with?(statement, "SET lock_timeout") or
              statement == "RESET lock_timeout" or
              raw_html_rewrite?(statement) or
              Enum.any?(core, &String.contains?(statement, &1)) or
              Enum.any?(departure_shapes, &String.contains?(statement, &1))
          end
        )

      # Every entry here is a column core's manifest does not know about, which
      # core's audit reports at :info and never as a failure. Adding one is a
      # decision, which is what this assertion is for — it fails until the new
      # column is written down.
      assert Enum.sort(extra) == [
               "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"archived_at\" timestamp with time zone",
               "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"integration_uuid\" uuid",
               "ALTER TABLE public.phoenix_kit_email_logs ADD COLUMN IF NOT EXISTS \"s3_key\" text",
               "ALTER TABLE public.phoenix_kit_email_verify_batches ADD COLUMN IF NOT EXISTS \"awaiting_smtp\" integer DEFAULT 0 NOT NULL",
               "COMMENT ON TABLE public.phoenix_kit_email_logs IS 'pke_schema:5'",
               "CREATE EXTENSION IF NOT EXISTS citext"
             ]
    end

    defp adopted_object?(object) do
      Enum.any?(@adopted_tables, fn table ->
        String.starts_with?(object.id, "table:" <> table) or
          String.starts_with?(object.id, "column:" <> table <> ".") or
          String.starts_with?(object.id, "constraint:" <> table <> ".") or
          (object.class == :index and
             match?(%{table: ^table}, elem(List.last(object.revisions), 1)))
      end)
    end
  end

  # V3's data step (see the moduledoc's "What V3 is"). Idempotent by
  # construction rather than by an `IF NOT EXISTS`: it only matches a
  # placeholder that is not already triple-braced, which
  # `migration_v3_raw_html_test.exs` proves against real rows.
  defp raw_html_rewrite?(statement),
    do: String.starts_with?(statement, "UPDATE public.phoenix_kit_email_templates SET html_body")

  defp create_table_statement(table) do
    Enum.find(
      Migrations.up_statements(),
      &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
    )
  end

  defp last_index_matching(statements, fun) do
    statements
    |> Enum.with_index()
    |> Enum.filter(fn {statement, _index} -> fun.(statement) end)
    |> List.last()
    |> elem(1)
  end

  describe "a pinned :version" do
    test "V1 emits V1's objects only, and stamps V1" do
      statements = Migrations.up_statements("public", 1)

      assert Enum.any?(statements, &String.contains?(&1, "\"integration_uuid\" uuid"))
      assert Enum.any?(statements, &String.contains?(&1, "integration_uuid_idx"))

      refute Enum.any?(statements, &String.contains?(&1, "\"archived_at\"")),
             "a host pinning version: 1 received V2's DDL — the exact surprise " <>
               "up/1's doc promises not to spring"

      refute Enum.any?(statements, &String.contains?(&1, "\"s3_key\""))
      refute Enum.any?(statements, &String.contains?(&1, "archived_at_idx"))

      assert Enum.any?(statements, &String.contains?(&1, "pke_schema:1"))
      refute Enum.any?(statements, &String.contains?(&1, "pke_schema:2"))
    end

    test "V2 emits both versions' objects, and stamps V2" do
      statements = Migrations.up_statements("public", 2)

      assert Enum.any?(statements, &String.contains?(&1, "\"integration_uuid\" uuid"))
      assert Enum.any?(statements, &String.contains?(&1, "\"archived_at\""))
      assert Enum.any?(statements, &String.contains?(&1, "\"s3_key\""))
      assert Enum.any?(statements, &String.contains?(&1, "archived_at_idx"))
      assert Enum.any?(statements, &String.contains?(&1, "pke_schema:2"))
      refute Enum.any?(statements, &raw_html_rewrite?/1)
      refute Enum.any?(statements, &String.contains?(&1, "pke_schema:3"))
      refute Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_verif"))
    end

    test "V3 adds the raw-HTML placeholder rewrite, after the tables exist, and stamps V3" do
      statements = Migrations.up_statements("public", 3)

      rewrite = Enum.find_index(statements, &raw_html_rewrite?/1)

      create =
        Enum.find_index(
          statements,
          &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_templates")
        )

      assert rewrite && create && rewrite > create
      assert Enum.at(statements, rewrite) =~ "line_items_html"
      assert Enum.at(statements, rewrite) =~ "line_items_table_html"
      assert Enum.any?(statements, &String.contains?(&1, "pke_schema:3"))
      refute Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_verif"))
      refute Enum.any?(statements, &String.contains?(&1, "pke_schema:4"))
    end

    test "V4 creates the four verification tables and stamps V4" do
      statements = Migrations.up_statements("public", 4)

      for table <- Enum.take(Migrations.owned_tables(), 4) do
        assert Enum.any?(
                 statements,
                 &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} (")
               ),
               "no CREATE TABLE for #{table}"
      end

      assert Enum.any?(statements, &String.contains?(&1, "pke_schema:4"))
      refute Enum.any?(statements, &String.contains?(&1, "pke_schema:3"))
      refute Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_verify_smtp_queue"))
      refute Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_verify_runners"))
      refute Enum.any?(statements, &String.contains?(&1, "awaiting_smtp"))
    end

    test "the rewrite follows the schema prefix" do
      rewrite = Enum.find(Migrations.up_statements("tenant_a", 3), &(&1 =~ "UPDATE "))

      assert rewrite =~ "UPDATE tenant_a.phoenix_kit_email_templates"
      refute rewrite =~ "public."
    end

    test "the adoption half is emitted at every version" do
      # Adoption is not versioned: it is "the tables core already made", and a
      # pinned version must still repair a missing one.
      for version <- [1, 2, 3, 4, 5] do
        statements = Migrations.up_statements("public", version)

        assert Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_logs")),
               "version #{version} emitted no adoption statements"
      end
    end
  end

  describe "V4 - the verification tables" do
    @owned_tables ~w(
      phoenix_kit_email_verifications
      phoenix_kit_email_verify_domains
      phoenix_kit_email_verify_batches
      phoenix_kit_email_verify_batch_items
      phoenix_kit_email_verify_smtp_queue
      phoenix_kit_email_verify_runners
    )

    test "the chain is at version 5 and owns exactly the six tables of the verification engine and the SMTP stage" do
      assert Migrations.current_version() == 5
      assert Migrations.owned_tables() == @owned_tables
    end

    test "module-owned tables are neither adopted nor known to core's manifest" do
      for table <- @owned_tables do
        refute table in Migrations.adopted_tables()

        refute Enum.any?(
                 ExpectedSchema.objects("public"),
                 &String.contains?(&1.id, table)
               ),
               "#{table} is in core's ExpectedSchema - it must stay module-owned"
      end
    end

    test "citext is ensured before the first table that uses it" do
      statements = Migrations.up_statements()
      extension = Enum.find_index(statements, &(&1 == "CREATE EXTENSION IF NOT EXISTS citext"))

      first_table =
        Enum.find_index(
          statements,
          &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_verif")
        )

      assert extension && first_table && extension < first_table
    end

    test "a batch is created before its items, whose foreign key points at it" do
      statements = Migrations.up_statements()

      batches =
        Enum.find_index(
          statements,
          &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_verify_batches (")
        )

      items =
        Enum.find_index(
          statements,
          &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_verify_batch_items (")
        )

      assert batches < items

      assert Enum.at(statements, items) =~
               "REFERENCES public.phoenix_kit_email_verify_batches (\"uuid\") ON DELETE CASCADE"
    end

    test "the address columns are citext and the result address is uniquely indexed" do
      verifications = create_table_statement("phoenix_kit_email_verifications")

      assert verifications =~ "\"email\" citext NOT NULL"
      assert verifications =~ "\"log\" jsonb DEFAULT '[]'::jsonb NOT NULL"

      for flag <- ~w(fake curse typo) do
        assert verifications =~ "\"#{flag}\" boolean DEFAULT false NOT NULL"
      end

      assert Enum.any?(
               Migrations.up_statements(),
               &(&1 =~
                   "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_verifications_email_idx")
             )

      assert Enum.any?(
               Migrations.up_statements(),
               &(&1 =~
                   "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_verify_batch_items_member_idx")
             )
    end

    test "the domain cache keeps one timestamp per cached fact" do
      domains = create_table_statement("phoenix_kit_email_verify_domains")

      for column <- ~w(mx_checked_at catch_all_checked_at grey_at last_smtp_at paused_until) do
        assert domains =~ "\"#{column}\" timestamp with time zone", "missing #{column}"
      end

      assert domains =~ "PRIMARY KEY (\"domain\")"
    end

    test "a custom prefix reaches every reference, including the uuid default" do
      for table <- @owned_tables do
        statement =
          Enum.find(
            Migrations.up_statements("tenant_a"),
            &String.starts_with?(&1, "CREATE TABLE IF NOT EXISTS tenant_a.#{table} (")
          )

        assert statement, "no tenant_a CREATE TABLE for #{table}"
        refute statement =~ "public."
      end
    end

    test "nothing in V4 touches an existing table" do
      v3 = MapSet.new(Migrations.up_statements("public", 3))

      new_statements =
        Migrations.up_statements("public", 4)
        |> Enum.reject(&MapSet.member?(v3, &1))

      for statement <- new_statements do
        refute statement =~ ~r/\A\s*(ALTER|UPDATE|DELETE)\b/i,
               "V4 changes existing data: #{statement}"
      end
    end
  end

  describe "V5 - the SMTP queue and the runners" do
    test "V5 adds the queue, the runners and the awaiting counter, and stamps V5" do
      v4 = MapSet.new(Migrations.up_statements("public", 4))

      added = Migrations.up_statements("public", 5) |> Enum.reject(&MapSet.member?(v4, &1))

      assert Enum.any?(
               added,
               &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_verify_smtp_queue (")
             )

      assert Enum.any?(
               added,
               &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_verify_runners (")
             )

      assert Enum.any?(added, &(&1 =~ ~s("awaiting_smtp" integer DEFAULT 0 NOT NULL)))
      assert Enum.any?(added, &(&1 =~ "pke_schema:5"))
    end

    test "the only change to an existing table is one added column on a V4 table of this chain" do
      v4 = MapSet.new(Migrations.up_statements("public", 4))

      changes =
        Migrations.up_statements("public", 5)
        |> Enum.reject(&MapSet.member?(v4, &1))
        |> Enum.filter(&(&1 =~ ~r/\A\s*(ALTER|UPDATE|DELETE|DROP)\b/i))

      assert changes == [
               "ALTER TABLE public.phoenix_kit_email_verify_batches ADD COLUMN IF NOT EXISTS \"awaiting_smtp\" integer DEFAULT 0 NOT NULL"
             ]
    end

    test "a live address is queued once: the unique index is partial on queued and leased" do
      statement =
        Enum.find(
          Migrations.up_statements(),
          &(&1 =~ "phoenix_kit_email_verify_smtp_queue_live_email_idx")
        )

      assert statement =~ "CREATE UNIQUE INDEX IF NOT EXISTS"
      assert statement =~ "(email) WHERE state IN ('queued', 'leased')"
    end

    test "a pinned older version emits none of it" do
      for version <- 1..4 do
        refute Enum.any?(
                 Migrations.up_statements("public", version),
                 &(&1 =~ "smtp_queue" or &1 =~ "verify_runners" or &1 =~ "awaiting_smtp")
               )
      end
    end

    test "down never drops a table or a column" do
      for target <- 0..4, statement <- Migrations.down_statements("public", target) do
        refute statement =~ ~r/\bDROP\b/i
      end
    end
  end
end
