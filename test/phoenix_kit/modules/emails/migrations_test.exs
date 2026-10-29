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

  alias PhoenixKit.Modules.Emails.Migrations

  @adopted_tables ~w(
    phoenix_kit_email_logs
    phoenix_kit_email_events
    phoenix_kit_email_blocklist
    phoenix_kit_email_metrics
    phoenix_kit_email_orphaned_events
  )

  describe "chain protocol" do
    test "current_version/0 is a positive integer and the marker table is the logs table" do
      assert is_integer(Migrations.current_version())
      assert Migrations.current_version() > 0
      assert Migrations.version_table() == "phoenix_kit_email_logs"
    end

    test "the retired email-templates table is neither created nor indexed by any version" do
      for version <- 1..Migrations.current_version(), prefix <- ["public", "tenant_a"] do
        statements = Migrations.up_statements(prefix, version)

        refute Enum.any?(
                 statements,
                 &(&1 =~ ~r/CREATE (UNIQUE )?(TABLE|INDEX).*email_templates/s)
               )

        refute Enum.any?(statements, &(&1 =~ ~r/ALTER TABLE.*email_templates/s))

        # The one statement that still names it is V3's data step, and it only
        # acts where the table exists.
        for statement <- Enum.filter(statements, &(&1 =~ "email_templates")) do
          assert statement =~ "to_regclass('#{prefix}.phoenix_kit_email_templates') IS NOT NULL"
        end
      end

      refute "phoenix_kit_email_templates" in Migrations.adopted_tables()
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

      # No adopted object carries the marker any more: the only one was the
      # email-templates table's, and that table is not created here.
      refute Enum.any?(
               Migrations.up_statements("public"),
               &(&1 =~ "phoenix_kit_email_templates_uuid_idx")
             )
    end
  end

  # V3's data step (see the moduledoc's "What V3 is"). Idempotent by
  # construction rather than by an `IF NOT EXISTS`: it only matches a
  # placeholder that is not already triple-braced, which
  # `migration_v3_raw_html_test.exs` proves against real rows.
  defp raw_html_rewrite?(statement),
    do: statement =~ "UPDATE public.phoenix_kit_email_templates SET html_body"

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
          &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_email_logs")
        )

      assert rewrite && create && rewrite > create
      assert Enum.at(statements, rewrite) =~ "line_items_html"
      assert Enum.at(statements, rewrite) =~ "line_items_table_html"
      assert Enum.any?(statements, &String.contains?(&1, "pke_schema:3"))
      refute Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_verif"))
      refute Enum.any?(statements, &String.contains?(&1, "pke_schema:4"))
    end

    test "V4 and V5 add nothing of their own, and stamp their own marker" do
      v3 = Migrations.up_statements("public", 3) |> Enum.reject(&(&1 =~ "pke_schema:"))

      for version <- [4, 5] do
        statements = Migrations.up_statements("public", version)

        assert Enum.reject(statements, &(&1 =~ "pke_schema:")) == v3
        assert Enum.any?(statements, &String.contains?(&1, "pke_schema:#{version}"))
        refute Enum.any?(statements, &String.contains?(&1, "pke_schema:#{version - 1}"))
      end
    end

    test "the rewrite follows the schema prefix" do
      rewrite = Enum.find(Migrations.up_statements("tenant_a", 3), &(&1 =~ "UPDATE "))

      assert rewrite =~ "UPDATE tenant_a.phoenix_kit_email_templates"
      refute rewrite =~ "public."
    end

    test "the adoption half is emitted at every version" do
      # Adoption is not versioned: it is "the tables core already made", and a
      # pinned version must still repair a missing one.
      for version <- [1, 2, 3, 4, 5, 6] do
        statements = Migrations.up_statements("public", version)

        assert Enum.any?(statements, &String.contains?(&1, "phoenix_kit_email_logs")),
               "version #{version} emitted no adoption statements"
      end
    end
  end

  describe "the address verification tables were removed from this module" do
    @removed_fragments ~w(phoenix_kit_email_verif awaiting_smtp citext)

    test "no version, under any prefix, creates, alters or indexes one" do
      for prefix <- ["public", "tenant_a"],
          version <- 1..6,
          statement <- Migrations.up_statements(prefix, version),
          fragment <- @removed_fragments do
        refute statement =~ fragment,
               "version #{version} (#{prefix}) still mentions #{fragment}: #{statement}"
      end
    end

    test "nothing in the chain drops anything, at any version" do
      for version <- 1..6, statement <- Migrations.up_statements("public", version) do
        refute statement =~ ~r/\bDROP\b/i, "destructive statement: #{statement}"
      end

      for target <- 0..6, statement <- Migrations.down_statements("public", target) do
        refute statement =~ ~r/\bDROP\b/i, "destructive statement: #{statement}"
      end
    end
  end
end
