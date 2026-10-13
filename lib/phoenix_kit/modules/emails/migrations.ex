defmodule PhoenixKit.Modules.Emails.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_emails` — the
  decentralized-migrations protocol core's `mix phoenix_kit.update`
  discovers via `c:PhoenixKit.Module.migration_module/0`:
  `current_version/0` + `migrated_version_runtime/1` + idempotent `up/1` +
  version-aware `down/1`. `PhoenixKit.Modules.Legal.Migrations` is the
  reference implementation this chain is shaped after — same situation, and
  V1 here is the same kind of step: an ADOPTION, not a create.

  ## Ownership history — read before touching

  Every table this chain names was created by core, back when email
  tracking still lived inside core, and today ships in core's squashed
  V135 baseline (plus later deltas — see "Where the DDL comes from"). When
  the module was extracted into this package the tables stayed in core's
  chain, exactly as `phoenix_kit_consent_logs` did for
  `phoenix_kit_legal`. So on every existing install the tables predate this
  chain and `CREATE TABLE IF NOT EXISTS` finds them already there.

  This chain moves ownership of their FUTURE shape here. It is deliberately
  a TRANSITIONAL duplication: right now BOTH core's baseline and this
  chain can create these tables, and the statements are written to be
  shape-identical so that it does not matter which one wins. The next step
  is a core release that stops creating them, after which this chain is
  their only creator. See
  `dev_docs/reports/2026-08-12-emails-table-adoption.md` for the full plan,
  including the excluded-object protocol core's `ExpectedSchema` manifest
  needs before that release.

  ## What V1 is

  V1 is an ADOPTION step plus exactly one shape change:

    * **Adoption.** `CREATE TABLE IF NOT EXISTS` + `ADD COLUMN IF NOT
      EXISTS` + `CREATE INDEX IF NOT EXISTS` + guarded `ADD CONSTRAINT` for
      the six tables this package owns. On an existing install every one of
      them is a no-op and the only new object is the `pke_schema:1` marker.
      On a hypothetical future install whose core baseline no longer
      creates them, the same statements create them — with core's exact
      object names, column types, widths and defaults.
    * **One genuine change:** a nullable `integration_uuid` (uuid) column
      plus its index on `phoenix_kit_email_logs`. Before it, a log recorded
      only the provider *kind* (`"aws_ses"`, `"brevo_api"`), so with
      several accounts of the same kind configured there was no way to tell
      WHICH account sent a message — which is what per-account event
      tracking needs (see `PhoenixKit.Modules.Emails.AwsIntegrations`).
      Nullable because every pre-existing row genuinely has no known
      account, and because the stamp is best-effort on the send path (see
      `PhoenixKit.Modules.Emails.Interceptor`): an unstamped row must
      remain a valid row, not a constraint violation.

  Because the adoption half changes no shape, core's `ExpectedSchema`
  manifest stays accurate for it and NO core release is required. The
  `integration_uuid` column is the one declared deviation: core's audit
  reports an unknown column as an `:info`-level "extra column, not in the
  manifest" finding, never a failure — checked, and accepted.

  ## What V2 is

  Two nullable columns on `phoenix_kit_email_logs`, `archived_at`
  (timestamptz) and `s3_key` (text), plus a partial index on the pair.
  They are what turns S3 archival from a fire-and-forget upload into a
  resumable one: before them the only record that a row had been shipped to
  cold storage was the row's own deletion, so an archival run could not be
  re-run without duplicating objects, and a run configured NOT to delete
  left no trace at all.

  Nullable and without a default on purpose — "never archived" is the
  absence of a timestamp, and every pre-existing row genuinely was never
  archived. The index is `WHERE archived_at IS NOT NULL`, because the
  question the job asks is "which of these did I already ship", and on a
  healthy install the answer set is the small one.

  Same deviation status as `integration_uuid`: unknown to core's manifest,
  reported at `:info`, never a failure.

  ## What V3 is

  A data step, no shape change: in every stored `html_body` locale value,
  `{{name}}` becomes `{{{name}}}` for `line_items_html` and
  `line_items_table_html` — billing's ready-made table. The two names are
  frozen into the migration; they match
  `PhoenixKit.Modules.Emails.Template.raw_html_variables/0` today, but a name
  added to that list later does not change what V3 rewrites.

  Since V3's release `{{name}}` is HTML-escaped in `html_body` and
  `{{{name}}}` is the raw form (see `Template.substitute_variables/3`).
  Rows seeded or edited before then carry the double-brace spelling of these
  names and would otherwise depend on the renderer's fallback for them.
  After the rewrite the stored content says what it means, and
  `mix phoenix_kit_emails.templates.export` copies it into files unchanged.

  Idempotent by construction: only a placeholder that is not already inside
  a third pair of braces matches, so a second run finds nothing. `subject`
  and `text_body` are untouched — they are never escaped. A row whose
  `html_body` is not a locale map, and a locale value that is not a string,
  are left alone rather than failing the step.

  `down/1` to a target below 3 runs the inverse, `{{{name}}}` → `{{name}}`,
  for the same names only: code older than V3 has no raw form and renders
  `{{{name}}}` as `{` + value + `}`.

  ## Which tables, and which one is NOT here

  Adopted: `phoenix_kit_email_logs`, `phoenix_kit_email_events`,
  `phoenix_kit_email_blocklist`, `phoenix_kit_email_templates`,
  `phoenix_kit_email_metrics`, `phoenix_kit_email_orphaned_events`.

  "Nothing outside this package READS them" is true; "nothing outside this
  package DEPENDS on them" is not, and the difference matters for the release
  that follows. Core's V135 creates
  `fk_newsletters_broadcasts_template` — `phoenix_kit_newsletters_broadcasts.template_uuid`
  referencing `phoenix_kit_email_templates(uuid)` — so a core release that
  stops creating `phoenix_kit_email_templates` breaks a FRESH install outright
  (core's chain runs before every module chain, so the FK would point at a
  table that does not exist yet), and breaks it permanently on an install that
  does not have this package at all. That FK has to move or go in the same
  release; see the "Transitional state" section of
  `dev_docs/reports/2026-08-12-emails-table-adoption.md`.

  **`phoenix_kit_email_send_profiles` is deliberately NOT adopted.** The
  send-profile system lives in CORE (`PhoenixKit.Email.SendProfile` /
  `PhoenixKit.Email.SendProfiles`) and drives `PhoenixKit.Mailer`'s send
  path with or without this package installed. This package only READS it
  (through `AwsIntegrations` / `BrevoIntegrations`). Adopting a table core
  itself depends on would be the mirror of the mistake the legal package's
  own report documents — claiming ownership of something that outlives you.

  Two of the adopted tables — `phoenix_kit_email_metrics` and
  `phoenix_kit_email_orphaned_events` — currently have no reader in this
  package (no Ecto schema, no query); they are pre-extraction leftovers.
  They are adopted anyway: nothing else in the ecosystem touches them, and
  leaving them out would strand them with no owner at all the moment core
  stops creating them.

  ## Where the DDL comes from

  Mechanically extracted from core's own `ExpectedSchema`
  manifest — the same object list `mix phoenix_kit.doctor` and
  `mix phoenix_kit.repair` verify a live database against — so every
  statement is byte-identical to what core would emit for the same object,
  at the manifest's CURRENT shape (not just the V135 snapshot). It was not
  retyped from the baseline by hand, because that is precisely how the
  legal package accumulated three disagreeing DDL copies of one table.
  `test/phoenix_kit/modules/emails/migrations_test.exs` pins the
  correspondence: it compares every statement here against the live
  manifest and fails on drift, while skipping objects the manifest no
  longer declares — which is what makes it survive, rather than block, the
  core release that removes them.

  ### Where this chain deliberately differs from the manifest

  Four departures, each narrow and each pinned by name in
  `migrations_test.exs`, so the list cannot grow quietly:

    * **`CREATE TABLE` carries core's full column list** rather than the
      manifest's bare `CREATE TABLE ... ()`. The manifest's form is repair DDL
      and cannot express `NOT NULL` on a column without a default — see
      `table_statements/0`.
    * **Primary keys are probed by `contype`, not by name**, and
    * **the foreign key is added `NOT VALID`** — see `constraint_statements/0`.
      Both exist because this chain replays constraints on long-lived
      databases that core's baseline never re-runs on.
    * **`gin_trgm_ops` is unqualified.** The manifest hard-codes
      `public.gin_trgm_ops`, which is a `pg_dump`-shaped rendering of what
      core's V137 actually writes unqualified. An operator class lives in the
      schema its EXTENSION was installed into, and `pg_trgm` is not required
      to be in `public`: hard-coding the schema turns "trigram search works"
      into "the migration fails" on any install that put the extension
      elsewhere. Unqualified resolves through `search_path`, which is what
      core's own DDL relies on.

  Two dependencies stay core's: the `uuid_generate_v7()` function used in the
  `uuid` defaults, and the `pg_trgm` extension behind the `gin_trgm_ops`
  indexes. The operator class is referenced UNQUALIFIED (see the departures
  above): it lives in whatever schema `pg_trgm` was installed into, which is
  not required to be `public` and is not the install's own prefix either, so
  `search_path` — the way core's V137 writes it — is the only spelling that
  works on every install.

  Both are core infrastructure shared by every module, and core's chain
  runs before any module chain (`mix phoenix_kit.update`), so they are
  always in place first.

  ## Locking

  The `CREATE INDEX` statements are plain, not `CONCURRENTLY`: this chain runs
  inside core's generated migration, and `CONCURRENTLY` cannot run in a
  transaction (`@disable_ddl_transaction` belongs to the migration module core
  generates, not to this one — it is not ours to set).

  On the installs this matters for, the DDL itself costs nothing: every
  statement is `IF NOT EXISTS` and every object already exists, so each one is
  a catalog lookup. The LOCKS are not free, though — Postgres acquires the
  lock before it evaluates `IF NOT EXISTS`, so 96 `ADD COLUMN IF NOT EXISTS`
  against `phoenix_kit_email_logs` each want `ACCESS EXCLUSIVE` on the busiest
  table in the module. `up_statements/1` therefore opens with
  `SET LOCAL lock_timeout` (see `lock_timeout_statement/0`): behind a
  long-running reader the migration fails in five seconds with a clear error
  instead of hanging the deploy and queueing every query on that table behind
  it. Retry during a quiet window.

  Be precise about what that costs, because the earlier version of this
  paragraph was not: `ADD COLUMN IF NOT EXISTS` takes `ACCESS EXCLUSIVE`, not
  `SHARE`, and it takes it even when the column already exists and the
  statement does nothing. `ACCESS EXCLUSIVE` blocks READS as well as writes,
  and every lock in a transaction is held until COMMIT — so for the duration
  of V01, `phoenix_kit_email_logs` is unavailable to the application, not
  merely unwritable. On a healthy install that is milliseconds of catalog
  lookups; the number that matters is how long the whole chain takes, not any
  one statement.

  The one statement that does real WORK on an existing install is the new
  `integration_uuid` index. Expect seconds on a table of a few million rows —
  and, because it runs inside the same transaction, that is seconds with the
  table fully locked. A host that cannot afford it should create the index
  `CONCURRENTLY` by hand first (outside any transaction), after which this
  statement finds it and does nothing:

      CREATE INDEX CONCURRENTLY IF NOT EXISTS phoenix_kit_email_logs_integration_uuid_idx
        ON public.phoenix_kit_email_logs USING btree (integration_uuid);

  Run `mix phoenix_kit.doctor` before upgrading. It reports exactly the two
  conditions that make this chain's constraint statements interesting — a
  drifted `phoenix_kit_email_events` shape and orphaned `email_log_uuid`
  rows — and it is cheaper to know beforehand than to find out from a failed
  deploy.

  ## One known, harmless cosmetic difference

  Two partial indexes on `phoenix_kit_email_events` were originally written
  by core's V137 as `WHERE event_type NOT IN ('open', 'click')`, while the
  manifest carries the `pg_get_indexdef` round-trip of that predicate. Both
  spellings mean the same thing and produce the same index under the same
  name, but Postgres renders the two parse trees differently, so
  `pg_get_indexdef` output differs by parenthesisation between a
  core-CREATED and a manifest-created database. This is core's own
  behaviour — its repair path emits the manifest form too — and nothing
  checks index definitions textually (the manifest's own `check` is a
  catalog existence probe by name). Verified end to end against a real
  database: dropping all six tables and replaying `up_statements/1` yields
  IDENTICAL columns and constraints, and identical indexes apart from
  these two renderings.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops a table and never
  drops a column. These tables carry the delivery history and, on every
  install that exists today, were created by core — rolling the MODULE
  back must not destroy either. Re-running `up/1` after a rollback would
  return the tables, but not the rows. The ownership test pins this by
  asserting that no statement this module can emit matches `DROP`.

  The migrated version is tracked as a `pke_schema:<N>` `COMMENT` on
  `phoenix_kit_email_logs` (the marker convention from the legal/projects
  chains, namespaced for this package). A marker-less table reads as
  version 0 — the core-baseline shape from before this chain existed.
  """

  use Ecto.Migration

  @current_version 3
  @marker_prefix "pke_schema:"
  @version_table "phoenix_kit_email_logs"

  # Core's own convention for schema-anchored SQL (see
  # `PhoenixKit.Migrations.ExpectedSchema`'s "Conventions"): statements are
  # stored with this token and it is replaced with the validated prefix on
  # the way out. Kept rather than string interpolation because the
  # constraint DO-blocks also carry the schema as an `nspname` string
  # LITERAL, which interpolation makes easy to get subtly wrong.
  @schema_token "__SCHEMA__"

  # See lock_timeout_statement/0.
  @lock_timeout "5s"

  # A handful of core's index names embed the runtime prefix in their OWN
  # name rather than only schema-qualifying the table (V56's
  # `prefix_index_name/2`): bare on `public`, `"<prefix>_"` everywhere else.
  # Core's manifest carries that as this marker and resolves it alongside
  # `@schema_token`; exactly one adopted object here has one
  # (`phoenix_kit_email_templates_uuid_idx`), and getting it wrong would
  # create a SECOND index under a different name on every non-public
  # install — so the marker is carried through verbatim rather than
  # flattened to the public-schema spelling.
  @name_marker_exempt "__PK_NAME_EXEMPT__"

  ## --- Adopted core-created objects (see "Where the DDL comes from") ---

  @adopted_tables [
    "phoenix_kit_email_events",
    "phoenix_kit_email_logs",
    "phoenix_kit_email_blocklist",
    "phoenix_kit_email_templates",
    "phoenix_kit_email_metrics",
    "phoenix_kit_email_orphaned_events"
  ]

  @adopted_columns [
    {"phoenix_kit_email_events", 10, "\"bounce_type\" character varying(255)", false},
    {"phoenix_kit_email_events", 11, "\"complaint_type\" character varying(255)", false},
    {"phoenix_kit_email_events", 4, "\"event_data\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_events", 3, "\"event_type\" character varying(255)", true},
    {"phoenix_kit_email_events", 8, "\"geo_location\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_events", 12, "\"inserted_at\" timestamp with time zone", true},
    {"phoenix_kit_email_events", 6, "\"ip_address\" character varying(255)", false},
    {"phoenix_kit_email_events", 9, "\"link_url\" character varying(255)", false},
    {"phoenix_kit_email_events", 5,
     "\"occurred_at\" timestamp with time zone DEFAULT now() NOT NULL", true},
    {"phoenix_kit_email_events", 13, "\"updated_at\" timestamp with time zone", true},
    {"phoenix_kit_email_events", 7, "\"user_agent\" character varying(255)", false},
    {"phoenix_kit_email_logs", 11, "\"attachments_count\" integer DEFAULT 0 NOT NULL", true},
    {"phoenix_kit_email_logs", 8, "\"body_full\" text", false},
    {"phoenix_kit_email_logs", 7, "\"body_preview\" text", false},
    {"phoenix_kit_email_logs", 10, "\"campaign_id\" character varying(255)", false},
    {"phoenix_kit_email_logs", 18, "\"configuration_set\" character varying(255)", false},
    {"phoenix_kit_email_logs", 17, "\"delivered_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 14, "\"error_message\" text", false},
    {"phoenix_kit_email_logs", 4, "\"from\" character varying(255)", true},
    {"phoenix_kit_email_logs", 6, "\"headers\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_logs", 22, "\"inserted_at\" timestamp with time zone", true},
    {"phoenix_kit_email_logs", 2, "\"message_id\" character varying(255)", true},
    {"phoenix_kit_email_logs", 19, "\"message_tags\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_logs", 20,
     "\"provider\" character varying(255) DEFAULT 'unknown'::character varying NOT NULL", true},
    {"phoenix_kit_email_logs", 13, "\"retry_count\" integer DEFAULT 0 NOT NULL", true},
    {"phoenix_kit_email_logs", 16, "\"sent_at\" timestamp with time zone DEFAULT now() NOT NULL",
     true},
    {"phoenix_kit_email_logs", 12, "\"size_bytes\" integer", false},
    {"phoenix_kit_email_logs", 15,
     "\"status\" character varying(255) DEFAULT 'sent'::character varying NOT NULL", true},
    {"phoenix_kit_email_logs", 5, "\"subject\" character varying(255)", false},
    {"phoenix_kit_email_logs", 9, "\"template_name\" character varying(255)", false},
    {"phoenix_kit_email_logs", 3, "\"to\" character varying(255)", true},
    {"phoenix_kit_email_logs", 23, "\"updated_at\" timestamp with time zone", true},
    {"phoenix_kit_email_blocklist", 2, "\"email\" character varying(255)", true},
    {"phoenix_kit_email_blocklist", 4, "\"expires_at\" timestamp with time zone", false},
    {"phoenix_kit_email_blocklist", 6,
     "\"inserted_at\" timestamp with time zone DEFAULT now() NOT NULL", true},
    {"phoenix_kit_email_blocklist", 3, "\"reason\" character varying(255)", true},
    {"phoenix_kit_email_blocklist", 7,
     "\"updated_at\" timestamp with time zone DEFAULT now() NOT NULL", true},
    {"phoenix_kit_email_events", 15, "\"delay_type\" character varying(255)", false},
    {"phoenix_kit_email_events", 17, "\"failure_reason\" character varying(255)", false},
    {"phoenix_kit_email_events", 14, "\"reject_reason\" character varying(255)", false},
    {"phoenix_kit_email_events", 16, "\"subscription_type\" character varying(255)", false},
    {"phoenix_kit_email_logs", 24, "\"aws_message_id\" character varying(255)", false},
    {"phoenix_kit_email_logs", 25, "\"bounced_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 28, "\"clicked_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 26, "\"complained_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 27, "\"opened_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 29, "\"body_compressed\" boolean DEFAULT false NOT NULL", true},
    {"phoenix_kit_email_templates", 10,
     "\"category\" character varying(255) DEFAULT 'transactional'::character varying NOT NULL",
     true},
    {"phoenix_kit_email_templates", 20, "\"created_by_user_uuid\" uuid", false},
    {"phoenix_kit_email_templates", 6, "\"description\" jsonb", false},
    {"phoenix_kit_email_templates", 5, "\"display_name\" jsonb", true},
    {"phoenix_kit_email_templates", 8, "\"html_body\" jsonb", true},
    {"phoenix_kit_email_templates", 22, "\"inserted_at\" timestamp with time zone", true},
    {"phoenix_kit_email_templates", 17, "\"is_system\" boolean DEFAULT false NOT NULL", true},
    {"phoenix_kit_email_templates", 15, "\"last_used_at\" timestamp with time zone", false},
    {"phoenix_kit_email_templates", 13, "\"metadata\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_templates", 3, "\"name\" character varying(255)", true},
    {"phoenix_kit_email_templates", 4, "\"slug\" character varying(255)", true},
    {"phoenix_kit_email_templates", 11,
     "\"status\" character varying(255) DEFAULT 'draft'::character varying NOT NULL", true},
    {"phoenix_kit_email_templates", 7, "\"subject\" jsonb", true},
    {"phoenix_kit_email_templates", 9, "\"text_body\" jsonb", true},
    {"phoenix_kit_email_templates", 23, "\"updated_at\" timestamp with time zone", true},
    {"phoenix_kit_email_templates", 21, "\"updated_by_user_uuid\" uuid", false},
    {"phoenix_kit_email_templates", 14, "\"usage_count\" integer DEFAULT 0 NOT NULL", true},
    {"phoenix_kit_email_templates", 2,
     "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL", true},
    {"phoenix_kit_email_templates", 12, "\"variables\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_templates", 16, "\"version\" integer DEFAULT 1 NOT NULL", true},
    {"phoenix_kit_email_logs", 33, "\"delayed_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 32, "\"failed_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 30, "\"queued_at\" timestamp with time zone", false},
    {"phoenix_kit_email_logs", 31, "\"rejected_at\" timestamp with time zone", false},
    {"phoenix_kit_email_metrics", 6, "\"inserted_at\" timestamp with time zone", true},
    {"phoenix_kit_email_metrics", 4, "\"metadata\" jsonb DEFAULT '{}'::jsonb", false},
    {"phoenix_kit_email_metrics", 5, "\"metric_date\" date DEFAULT CURRENT_DATE NOT NULL", true},
    {"phoenix_kit_email_metrics", 2, "\"metric_key\" character varying(255)", true},
    {"phoenix_kit_email_metrics", 7, "\"updated_at\" timestamp with time zone", true},
    {"phoenix_kit_email_metrics", 3, "\"value\" bigint DEFAULT 0 NOT NULL", true},
    {"phoenix_kit_email_orphaned_events", 2, "\"aws_message_id\" character varying(255)", true},
    {"phoenix_kit_email_orphaned_events", 9, "\"error_message\" text", false},
    {"phoenix_kit_email_orphaned_events", 4, "\"event_data\" jsonb DEFAULT '{}'::jsonb NOT NULL",
     true},
    {"phoenix_kit_email_orphaned_events", 3, "\"event_type\" character varying(255)", true},
    {"phoenix_kit_email_orphaned_events", 10, "\"inserted_at\" timestamp with time zone", true},
    {"phoenix_kit_email_orphaned_events", 6, "\"matched\" boolean DEFAULT false NOT NULL", true},
    {"phoenix_kit_email_orphaned_events", 8, "\"matched_at\" timestamp with time zone", false},
    {"phoenix_kit_email_orphaned_events", 5,
     "\"received_at\" timestamp with time zone DEFAULT now() NOT NULL", true},
    {"phoenix_kit_email_orphaned_events", 11, "\"updated_at\" timestamp with time zone", true},
    {"phoenix_kit_email_blocklist", 8,
     "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL", true},
    {"phoenix_kit_email_events", 18,
     "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL", true},
    {"phoenix_kit_email_logs", 34, "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL",
     true},
    {"phoenix_kit_email_metrics", 8,
     "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL", true},
    {"phoenix_kit_email_orphaned_events", 12,
     "\"uuid\" uuid DEFAULT __SCHEMA__.uuid_generate_v7() NOT NULL", true},
    {"phoenix_kit_email_blocklist", 9, "\"user_uuid\" uuid", false},
    {"phoenix_kit_email_events", 19, "\"email_log_uuid\" uuid", true},
    {"phoenix_kit_email_logs", 35, "\"user_uuid\" uuid", false},
    {"phoenix_kit_email_orphaned_events", 13, "\"matched_email_log_uuid\" uuid", false},
    {"phoenix_kit_email_logs", 36,
     "\"locale\" character varying(10) DEFAULT 'en'::character varying NOT NULL", true}
  ]

  @adopted_constraints [
    {"phoenix_kit_email_events", "phoenix_kit_email_events_pkey", "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_logs", "phoenix_kit_email_logs_pkey", "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_blocklist", "phoenix_kit_email_blocklist_pkey", "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_templates", "phoenix_kit_email_templates_pkey", "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_metrics", "phoenix_kit_email_metrics_pkey", "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_orphaned_events", "phoenix_kit_email_orphaned_events_pkey",
     "PRIMARY KEY (uuid)"},
    {"phoenix_kit_email_events", "fk_email_events_email_log_uuid",
     "FOREIGN KEY (email_log_uuid) REFERENCES __SCHEMA__.phoenix_kit_email_logs(uuid) ON DELETE CASCADE"}
  ]

  @adopted_indexes [
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_events_occurred_at_idx ON __SCHEMA__.phoenix_kit_email_events USING btree (occurred_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_events_type_occurred_at_idx ON __SCHEMA__.phoenix_kit_email_events USING btree (event_type, occurred_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_campaign_id_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (campaign_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_logs_message_id_uidx ON __SCHEMA__.phoenix_kit_email_logs USING btree (message_id)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_provider_sent_at_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (provider, sent_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_sent_at_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (sent_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_status_sent_at_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (status, sent_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_template_name_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (template_name)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_to_sent_at_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (\"to\", sent_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_email_expires_idx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (email, expires_at)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_email_uidx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (email)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_expires_at_idx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (expires_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_reason_inserted_idx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (reason, inserted_at)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_logs_aws_message_id_index ON __SCHEMA__.phoenix_kit_email_logs USING btree (aws_message_id) WHERE (aws_message_id IS NOT NULL)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_category_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (category)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_category_status_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (category, status)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_inserted_at_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (inserted_at)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_is_system_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (is_system)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_last_used_at_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (last_used_at)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_templates_name_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (name)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_templates_slug_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (slug)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_status_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (status)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_status_is_system_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (status, is_system)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_usage_count_index ON __SCHEMA__.phoenix_kit_email_templates USING btree (usage_count)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_message_ids_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (message_id, aws_message_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_logs_aws_message_id_uidx ON __SCHEMA__.phoenix_kit_email_logs USING btree (aws_message_id) WHERE (aws_message_id IS NOT NULL)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_metrics_date_idx ON __SCHEMA__.phoenix_kit_email_metrics USING btree (metric_date)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_metrics_key_date_uidx ON __SCHEMA__.phoenix_kit_email_metrics USING btree (metric_key, metric_date)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_orphaned_events_aws_id_idx ON __SCHEMA__.phoenix_kit_email_orphaned_events USING btree (aws_message_id)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_orphaned_events_matched_idx ON __SCHEMA__.phoenix_kit_email_orphaned_events USING btree (matched)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_orphaned_events_type_received_idx ON __SCHEMA__.phoenix_kit_email_orphaned_events USING btree (event_type, received_at)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_uuid_idx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_events_uuid_idx ON __SCHEMA__.phoenix_kit_email_events USING btree (uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_logs_uuid_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_metrics_uuid_idx ON __SCHEMA__.phoenix_kit_email_metrics USING btree (uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_orphaned_events_uuid_idx ON __SCHEMA__.phoenix_kit_email_orphaned_events USING btree (uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_blocklist_user_uuid_idx ON __SCHEMA__.phoenix_kit_email_blocklist USING btree (user_uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_events_email_log_uuid_idx ON __SCHEMA__.phoenix_kit_email_events USING btree (email_log_uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_user_uuid_idx ON __SCHEMA__.phoenix_kit_email_logs USING btree (user_uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_created_by_user_uuid_idx ON __SCHEMA__.phoenix_kit_email_templates USING btree (created_by_user_uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_templates_updated_by_user_uuid_idx ON __SCHEMA__.phoenix_kit_email_templates USING btree (updated_by_user_uuid)",
    "CREATE UNIQUE INDEX IF NOT EXISTS __PK_NAME_EXEMPT__phoenix_kit_email_templates_uuid_idx ON __SCHEMA__.phoenix_kit_email_templates USING btree (uuid)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_orphaned_events_matched_log_uuid_idx ON __SCHEMA__.phoenix_kit_email_orphaned_events USING btree (matched_email_log_uuid)",
    "CREATE INDEX IF NOT EXISTS idx_email_logs_locale ON __SCHEMA__.phoenix_kit_email_logs USING btree (locale)",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_events_log_uuid_event_type_index ON __SCHEMA__.phoenix_kit_email_events USING btree (email_log_uuid, event_type) WHERE ((event_type)::text <> ALL ((ARRAY['open'::character varying, 'click'::character varying])::text[]))",
    "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_email_events_log_uuid_type_occurred_index ON __SCHEMA__.phoenix_kit_email_events USING btree (email_log_uuid, event_type, occurred_at) WHERE ((event_type)::text = ANY ((ARRAY['open'::character varying, 'click'::character varying])::text[]))",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_campaign_id_trgm_index ON __SCHEMA__.phoenix_kit_email_logs USING gin (campaign_id gin_trgm_ops)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_compress_scan_index ON __SCHEMA__.phoenix_kit_email_logs USING btree (sent_at) WHERE (body_full IS NOT NULL)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_subject_trgm_index ON __SCHEMA__.phoenix_kit_email_logs USING gin (subject gin_trgm_ops)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_template_clicked_index ON __SCHEMA__.phoenix_kit_email_logs USING btree (template_name, clicked_at) WHERE (clicked_at IS NOT NULL)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_template_opened_index ON __SCHEMA__.phoenix_kit_email_logs USING btree (template_name, opened_at) WHERE (opened_at IS NOT NULL)",
    "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_to_trgm_index ON __SCHEMA__.phoenix_kit_email_logs USING gin (\"to\" gin_trgm_ops)"
  ]

  ## --- This chain's own objects ---

  # The one genuine shape change in V1 — see the moduledoc's "What V1 is".
  # `{version, table, definition}` — the version each column was introduced in.
  # `up/1` honours a pinned `:version`, and before these tags every statement
  # was emitted regardless of it: a host pinning `version: 1` got V2's columns
  # anyway, under a `pke_schema:1` marker. That is exactly the "silent
  # surprise at V2" the `up/1` doc promises not to have; with one version in
  # existence there was no way to observe it.
  @owned_columns [
    {1, "phoenix_kit_email_logs", "\"integration_uuid\" uuid"},
    # V2. Both nullable, and deliberately without a default: "not archived"
    # is the absence of a timestamp, not a sentinel, and every row that
    # predates the columns genuinely was never archived. `s3_key` is the
    # object the batch landed in — kept so an archived row can be traced back
    # to its file without reading the whole bucket, and so a second pass can
    # tell "already uploaded" from "never seen", which is what makes the
    # archival job safe to re-run.
    {2, "phoenix_kit_email_logs", "\"archived_at\" timestamp with time zone"},
    {2, "phoenix_kit_email_logs", "\"s3_key\" text"}
  ]

  # `{version, statement}` — see `@owned_columns` for why the tag exists.
  @owned_indexes [
    {1,
     "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_integration_uuid_idx " <>
       "ON #{@schema_token}.phoenix_kit_email_logs USING btree (integration_uuid)"},
    # V2. Partial: the archival job's question is "which of these did I
    # already ship", and on a healthy install the archived set is the small
    # one, so indexing the NULLs would be paying for the majority to answer
    # about the minority.
    {2,
     "CREATE INDEX IF NOT EXISTS phoenix_kit_email_logs_archived_at_idx " <>
       "ON #{@schema_token}.phoenix_kit_email_logs USING btree (archived_at) " <>
       "WHERE archived_at IS NOT NULL"}
  ]

  # V3's data step — see the moduledoc's "What V3 is". Postgres ARE syntax.
  # The lookbehind/lookahead keep a placeholder that already has a third pair
  # of braces (or a brace run that is not a plain placeholder) out of it,
  # which is what makes the step idempotent.
  #
  # The names are a frozen literal, NOT `Template.raw_html_variables/0`: a
  # shipped migration must do tomorrow what it did the day it was released,
  # and a name added to that list later is a decision for a new version, not
  # something an old one should start rewriting silently. The whitespace class
  # is spelled out because the renderer's `\s` is ASCII-only, and Postgres'
  # `\s` also matches other space characters.
  @raw_html_names Enum.join(~w(line_items_html line_items_table_html), "|")
  @ws "[ \\t\\r\\n\\f\\v]*"

  @escaped_raw_html_placeholder "(?<!\\{)\\{\\{#{@ws}(#{@raw_html_names})#{@ws}\\}\\}(?!\\})"
  @raw_raw_html_placeholder "(?<!\\{)\\{\\{\\{#{@ws}(#{@raw_html_names})#{@ws}\\}\\}\\}(?!\\})"

  @doc "The chain version this code needs."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pke_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Every table whose future shape this chain owns.

  `phoenix_kit_email_send_profiles` is deliberately absent — see the
  moduledoc.
  """
  @spec adopted_tables() :: [String.t()]
  def adopted_tables, do: @adopted_tables

  @doc false
  # The manifest-derived object data, exposed so the conformance test can
  # compare it against core's live `ExpectedSchema` without re-deriving the
  # statement shapes it is trying to verify.
  @spec adopted_objects() :: %{
          tables: [String.t()],
          columns: [{String.t(), non_neg_integer(), String.t(), boolean()}],
          constraints: [{String.t(), String.t(), String.t()}],
          indexes: [String.t()]
        }
  def adopted_objects do
    %{
      tables: @adopted_tables,
      columns: @adopted_columns,
      constraints: @adopted_constraints,
      indexes: @adopted_indexes
    }
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pke_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0`.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the convention the
    # legal chain inherited from the projects chain).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Applies every chain version up to `:version` in `opts` (default:
  `current_version/0`). Idempotent.

  The `:version` opt is what core's generated migration passes through.
  `@owned_columns` and `@owned_indexes` are tagged with the version that
  introduced them, so a host pinning `version: 1` gets V1's objects and a
  `pke_schema:1` marker — not V2's columns under a V1 stamp.
  """
  def up(opts \\ []) do
    target = target_version(opts)

    if target >= 1 do
      opts
      |> validated_prefix()
      |> up_statements(target)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `target` (`:version` in `opts`). Never drops a table or a
  column — see the moduledoc.
  """
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS`, or a catalog-guarded DO block
  for constraints, which have no `IF NOT EXISTS` form), so the chain can be
  re-run against a database at any version without a pre-flight check.

  Ordering is load-bearing: tables before their columns, the primary keys
  before the foreign key that references one of them, indexes last.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", version \\ @current_version) do
    prefix = validated_prefix(prefix: prefix)
    version = min(version, @current_version)

    # Indexes BEFORE constraints, deliberately. A foreign key requires a unique
    # index (or a primary key) on the columns it references, and the primary
    # key it would normally lean on is exactly what the type guard skips on a
    # drifted database. With `phoenix_kit_email_logs_uuid_idx` already in
    # place, the foreign key still gets created on a table whose primary key
    # could not be. The reverse order made the FK's fate depend on the PK's.
    statements =
      [lock_timeout_statement()] ++
        table_statements() ++
        column_statements(version) ++
        index_statements(version) ++
        constraint_statements() ++
        validate_foreign_key_statements() ++
        data_statements(version) ++
        [marker_statement(version), reset_lock_timeout_statement()]

    Enum.map(statements, &materialize(&1, prefix))
  end

  @doc """
  The SQL `down/1` executes, as data.

  Always the marker bookkeeping; rolling back below V3 also carries the
  inverse of V3's data step (`{{{name}}}` back to `{{name}}` for the two
  billing names), so code that predates triple braces reads the rows it
  expects.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0) do
    prefix = validated_prefix(prefix: prefix)

    statement =
      if target > 0 do
        marker_statement(target)
      else
        "COMMENT ON TABLE #{@schema_token}.#{@version_table} IS NULL"
      end

    rewrite =
      if target < 3,
        do: [rewrite_html_body_statement(@raw_raw_html_placeholder, "{{\\1}}")],
        else: []

    Enum.map(rewrite ++ [statement], &materialize(&1, prefix))
  end

  ## --- Statement builders ---

  # Same resolution core's `ExpectedSchema.Object` applies, so a statement
  # here and the manifest entry it was derived from stay byte-identical for
  # any prefix — which is what the conformance test asserts.
  defp materialize(sql, prefix) do
    sql
    |> String.replace(@schema_token, prefix)
    |> String.replace(@name_marker_exempt, if(prefix == "public", do: "", else: prefix <> "_"))
  end

  # The full table, in core's own column order, with core's defaults AND
  # its NOT NULLs — the shape a FRESH install must end up with.
  #
  # Deliberately NOT the manifest's own `CREATE TABLE ... ()` + per-column
  # `ADD COLUMN IF NOT EXISTS`: that pair is core's REPAIR form, and it
  # omits `NOT NULL` on any column without a default, because adding such a
  # column to a populated table is impossible. Replaying only the repair
  # form on an empty database therefore yields 26 nullable columns core
  # would have created `NOT NULL` — verified against a real database, which
  # is why this is a full column list. The repair-form statements are still
  # emitted afterwards (see `column_statements/0`), so an existing table
  # missing a column is still healed exactly the way core heals it.
  #
  # Our OWN columns are deliberately absent here: this statement is "the
  # table core would have created", and `@owned_columns` is the delta on
  # top of it.
  # Fail fast instead of queueing the whole host behind a long-running reader.
  #
  # Every statement here is `IF NOT EXISTS`, but Postgres takes the lock BEFORE
  # it evaluates the existence check: 96 `ADD COLUMN IF NOT EXISTS` against
  # `phoenix_kit_email_logs` each want ACCESS EXCLUSIVE, and one open
  # transaction reading that table is enough to make the whole migration wait —
  # with every subsequent query on the table queued behind it. Five seconds of
  # waiting, then a clear "canceling statement due to lock timeout", is a much
  # better failure than a deploy that hangs and takes the app's busiest table
  # with it. Retry during a quiet window.
  #
  # Session-scoped (`SET`, not `SET LOCAL`), and explicitly `RESET` at the end
  # of the chain — the shape V163 uses, for the reason V163 uses it.
  #
  # `SET LOCAL` reads better and reverts itself, but it is a WARNING and a
  # silent no-op outside a transaction, and outside a transaction is a
  # supported way to run this: `mix phoenix_kit.doctor` recommends
  # `@disable_ddl_transaction` to PgBouncer installs, and this package's own
  # `test_helper.exs` executes the chain statement by statement in autocommit.
  # A guard that quietly evaporates in exactly the deployment that most needs
  # it is worse than one that has to be handed back by hand.
  defp lock_timeout_statement, do: "SET lock_timeout = '#{@lock_timeout}'"

  # Session-scoped, so it has to be handed back. Paired with the SET above and
  # emitted last, after everything it protects.
  defp reset_lock_timeout_statement, do: "RESET lock_timeout"

  defp table_statements do
    Enum.map(@adopted_tables, fn table ->
      columns =
        @adopted_columns
        |> Enum.filter(fn {t, _pos, _definition, _not_null} -> t == table end)
        |> Enum.sort_by(fn {_t, pos, _definition, _not_null} -> pos end)
        |> Enum.map_join(",\n  ", &create_table_column/1)

      "CREATE TABLE IF NOT EXISTS #{@schema_token}.#{table} (\n  #{columns}\n)"
    end)
  end

  # The manifest's stored definition already ends in `NOT NULL` whenever the
  # column has a default (that being the case where adding it to a populated
  # table is safe). For the rest, the constraint is re-attached here — a
  # fresh CREATE TABLE has no rows to violate it.
  defp create_table_column({_table, _pos, definition, not_null}) do
    if not_null and not String.ends_with?(definition, " NOT NULL") do
      definition <> " NOT NULL"
    else
      definition
    end
  end

  defp column_statements(version) do
    adopted =
      Enum.map(@adopted_columns, fn {table, _pos, definition, _not_null} ->
        {table, definition}
      end)

    owned =
      for {introduced_in, table, definition} <- @owned_columns,
          introduced_in <= version,
          do: {table, definition}

    Enum.map(adopted ++ owned, fn {table, definition} ->
      "ALTER TABLE #{@schema_token}.#{table} ADD COLUMN IF NOT EXISTS #{definition}"
    end)
  end

  # Postgres has no `ADD CONSTRAINT IF NOT EXISTS`, so idempotency comes from a
  # catalog probe.
  #
  # This is the one place the chain deliberately does NOT reproduce core's
  # manifest string, and the reason is that we are the first thing to replay
  # these constraints on databases that have been running for years. Core's own
  # baseline does not re-run on them; core's V163 exists precisely because it
  # found production databases where `phoenix_kit_email_events.uuid` was
  # `varchar` and nullable with no primary key at all, and V163 itself gives up
  # and leaves the database unrepaired past a row-count or lock threshold. So
  # "the constraint is missing, add it" is a live case, not a hypothetical, and
  # it has to be safe.
  #
  # Two departures, both narrow:
  #
  #   * **Primary keys are guarded by `contype`, not by `conname`.** A table
  #     whose primary key exists under a DIFFERENT name passes a name-based
  #     probe and then fails the ALTER with "multiple primary keys for table
  #     are not allowed", aborting the host's whole migration. What we actually
  #     need to know is "does this table have a primary key", which is exactly
  #     what `contype = 'p'` asks.
  #   * **The foreign key is added `NOT VALID`.** `phoenix_kit.doctor` ships a
  #     dedicated check for orphaned `phoenix_kit_email_events.email_log_uuid`
  #     rows, which means they exist in the wild — and validating against them
  #     aborts the migration. `NOT VALID` enforces the constraint for every new
  #     row while leaving the existing ones alone. The constraint is present
  #     and named either way, which is what core's catalog probe checks for.
  #
  #     **It will not be validated for you.** Core has no `convalidated`
  #     anywhere: its constraint snapshot reads `conname`/`contype`/the
  #     definition, `repair` answers "already present" for an object that
  #     exists, and it only validates constraints it created itself. So on a
  #     populated table this stays NOT VALID indefinitely and nothing reports
  #     it. That is a deliberate, documented end state, not a hand-off — the
  #     operator who wants it validated cleans up the orphans and runs
  #     `ALTER TABLE <schema>.phoenix_kit_email_events
  #     VALIDATE CONSTRAINT fk_email_events_email_log_uuid;` themselves. See
  #     the report's "Running this on a database that has been alive for
  #     years".
  #
  # `to_regclass/1` returns NULL rather than raising for a table that does not
  # exist, so a chain running against a database that somehow lacks one of
  # these tables skips its constraint instead of blowing up mid-transaction.
  defp constraint_statements do
    Enum.map(@adopted_constraints, fn {table, name, definition} ->
      """
      DO $$
      DECLARE
        rel oid := to_regclass('#{@schema_token}.#{table}');
      BEGIN
        IF rel IS NULL THEN
          RETURN;
        END IF;

        IF EXISTS (
          SELECT 1
          FROM pg_constraint c
          WHERE c.conrelid = rel
            AND #{constraint_probe(name, definition)}
        ) THEN
          RETURN;
        END IF;

        IF NOT (#{type_precondition(definition, table)}) THEN
          RAISE NOTICE 'phoenix_kit_emails: skipping % — column types are not what this version expects; run mix phoenix_kit.doctor', '#{name}';
          RETURN;
        END IF;

        ALTER TABLE #{@schema_token}.#{table} ADD CONSTRAINT #{name} #{constraint_definition(definition)};
      EXCEPTION
        WHEN others THEN
          #{reraise_unless_populated(table, "could not add #{name}")}
      END
      $$\
      """
    end)
  end

  # Every column a constraint touches must already be the type this version
  # expects, on BOTH sides of a foreign key.
  #
  # `ADD COLUMN IF NOT EXISTS` matches on NAME alone, so on a database that
  # drifted (core's V163 documents exactly this: `phoenix_kit_email_events.uuid`
  # as a nullable `character varying`, no primary key at all) the column is
  # "already there" and stays the wrong type. The constraint that follows then
  # fails — and for a foreign key it fails at ADD time, on the type mismatch,
  # which `NOT VALID` does nothing about because it only defers the row scan.
  # One aborted statement, and the host's entire migration goes with it.
  #
  # So the type is checked first and a mismatch is skipped with a NOTICE.
  # Repairing the type is core's job — specifically V163, which is written for
  # exactly this drift. This chain's job is to not be the thing that breaks the
  # deploy on the way there.
  defp type_precondition(definition, table) do
    definition
    |> constrained_columns(table)
    |> Enum.map_join(" AND ", fn {column_table, column, type} ->
      "COALESCE((SELECT a.atttypid = '#{type}'::regtype " <>
        "FROM pg_attribute a " <>
        "WHERE a.attrelid = to_regclass('#{@schema_token}.#{column_table}') " <>
        "AND a.attname = '#{column}' AND a.attnum > 0 AND NOT a.attisdropped), false)"
    end)
  end

  # `{table, column, expected_type}` for every column a constraint depends on,
  # read out of the definition rather than hard-coded, so a future constraint
  # cannot silently skip the check. The expected type comes from
  # `@adopted_columns` — the same manifest data the column DDL is built from —
  # so the two can never disagree.
  defp constrained_columns(definition, table) do
    local =
      definition
      |> local_constraint_columns()
      |> Enum.map(&{table, &1, column_type(table, &1)})

    local ++ referenced_constraint_columns(definition)
  end

  defp local_constraint_columns(definition) do
    case Regex.run(~r/^(?:PRIMARY KEY|FOREIGN KEY) \(([^)]+)\)/, definition) do
      [_, columns] -> columns |> String.split(",") |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  defp referenced_constraint_columns(definition) do
    case Regex.run(~r/REFERENCES #{@schema_token}\.(\w+)\(([^)]+)\)/, definition) do
      [_, table, columns] ->
        columns
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&{table, &1, column_type(table, &1)})

      _ ->
        []
    end
  end

  # The declared type of one adopted column, as core declares it. Raises at
  # BUILD time (not on someone's database) if a constraint ever names a column
  # this chain does not adopt — which would mean the manifest data and the
  # constraint list have drifted apart.
  # Everything between the column name and the first modifier IS the type:
  # `character varying(255)` is two words, and taking only the first produced
  # `character` — which `::regtype` happily resolves to `bpchar`, so the
  # comparison would have been false forever and the constraint skipped on
  # every database, silently. Every constrained column is `uuid` today, so
  # nothing was actually broken; it was a trap armed for the first non-uuid
  # constraint.
  defp column_type(table, column) do
    Enum.find_value(@adopted_columns, fn {column_table, _pos, definition, _not_null} ->
      if column_table == table and String.starts_with?(definition, ~s("#{column}" )) do
        definition
        |> String.replace_prefix(~s("#{column}" ), "")
        |> String.split(~r/\s+(?:DEFAULT|NOT NULL)\b/, parts: 2)
        |> List.first()
        |> String.trim()
      end
    end) ||
      raise ArgumentError, "no adopted column #{table}.#{column} to take a type from"
  end

  # `NOT VALID` is the right answer for a populated table and the WRONG one for
  # an empty one: on a fresh install there are no rows to be orphaned, and
  # leaving the constraint unvalidated forever would mean every future install
  # carries a permanently-unvalidated FK that core's catalog probe (which
  # checks the name, not `convalidated`) would never flag.
  #
  # So validation is attempted exactly when it is free: the table is empty, so
  # the scan is nothing and it cannot fail on existing data. A populated table
  # skips it entirely — no scan, no lock, no risk — and the constraint stays
  # `NOT VALID` there INDEFINITELY. Nothing will finish the job later: core has
  # no `convalidated` anywhere, `repair` answers "already present" for a
  # constraint that exists, and it validates only constraints it created
  # itself. An operator who wants it validated cleans up the orphans
  # `phoenix_kit.doctor` reports and runs it by hand — the statement is in the
  # moduledoc.
  #
  # The EXCEPTION block is belt-and-braces: a failure inside a DO block rolls
  # back only that block's subtransaction, so even an unforeseen error here
  # cannot take the host's migration with it.
  defp validate_foreign_key_statements do
    Enum.flat_map(@adopted_constraints, fn {table, name, definition} ->
      if foreign_key?(definition) do
        [
          """
          DO $$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM #{@schema_token}.#{table} LIMIT 1) THEN
              ALTER TABLE #{@schema_token}.#{table} VALIDATE CONSTRAINT #{name};
            END IF;
          EXCEPTION
            WHEN others THEN
              RAISE NOTICE 'phoenix_kit_emails: left % unvalidated (%)', '#{name}', SQLERRM;
          END
          $$\
          """
        ]
      else
        []
      end
    end)
  end

  # Swallow on a populated table; RE-RAISE on an empty one.
  #
  # The asymmetry is the whole point. On a long-lived database a failure here
  # means the data has drifted, and taking the host's migration down over
  # something `mix phoenix_kit.doctor` is meant to report is the wrong trade —
  # degrade, name the object, move on. On an EMPTY table there is no data to
  # have drifted, so the only thing a failure can mean is that this chain is
  # wrong: a fresh install that swallowed it would stamp `pke_schema:1` over a
  # schema that is genuinely broken and report success. That one must be loud.
  #
  # `to_regclass` keeps the probe safe when the table itself is missing —
  # which, on the path that gets here, is already an error worth raising.
  defp reraise_unless_populated(table, what) do
    """
    IF to_regclass('#{@schema_token}.#{table}') IS NULL
       OR NOT EXISTS (SELECT 1 FROM #{@schema_token}.#{table} LIMIT 1) THEN
              RAISE;
            END IF;

            RAISE NOTICE 'phoenix_kit_emails: #{what} (%) — left for mix phoenix_kit.doctor', SQLERRM;\
    """
  end

  # The table an index statement is built on, for the emptiness probe above.
  defp index_table(statement) do
    case Regex.run(~r/ ON #{@schema_token}\.(\w+) /, statement) do
      [_, table] -> table
      _ -> raise ArgumentError, "cannot tell which table this index is on: #{statement}"
    end
  end

  # A primary key is identified by what it IS; everything else by its name.
  defp constraint_probe(name, definition) do
    if primary_key?(definition), do: "c.contype = 'p'", else: "c.conname = '#{name}'"
  end

  defp constraint_definition(definition) do
    if foreign_key?(definition), do: definition <> " NOT VALID", else: definition
  end

  defp primary_key?(definition), do: String.starts_with?(definition, "PRIMARY KEY")

  defp foreign_key?(definition), do: String.starts_with?(definition, "FOREIGN KEY")

  # Core's own `CREATE INDEX IF NOT EXISTS`, verbatim, wrapped so it cannot
  # abort the host's migration.
  #
  # `IF NOT EXISTS` covers the normal case — the index is already there and the
  # statement is a catalog lookup — but not the drifted one. A UNIQUE index
  # that is genuinely missing fails on duplicate rows; a trigram index fails
  # outright if `pg_trgm` is not installed. Either aborts the transaction, and
  # with it every other statement in the chain, on a database where the actual
  # problem is something core's repair is supposed to fix.
  #
  # The DDL inside is untouched, so the conformance test still matches it
  # against the manifest character for character — the guard is a wrapper, not
  # a rewrite.
  defp index_statements(version) do
    owned = for {introduced_in, sql} <- @owned_indexes, introduced_in <= version, do: sql

    Enum.map(@adopted_indexes ++ owned, fn statement ->
      """
      DO $$
      BEGIN
        #{statement};
      EXCEPTION
        WHEN others THEN
          #{reraise_unless_populated(index_table(statement), "could not create an index")}
      END
      $$\
      """
    end)
  end

  defp data_statements(version) when version >= 3,
    do: [rewrite_html_body_statement(@escaped_raw_html_placeholder, "{{{\\1}}}")]

  defp data_statements(_version), do: []

  # Rewrites `pattern` to `replacement` in every string value of every
  # locale-map `html_body`. Only rows that contain a match are touched, so a
  # re-run updates nothing (and an empty map is never aggregated into NULL).
  defp rewrite_html_body_statement(pattern, replacement) do
    """
    UPDATE #{@schema_token}.phoenix_kit_email_templates SET html_body = (
      SELECT jsonb_object_agg(
        e.key,
        CASE WHEN jsonb_typeof(e.value) = 'string'
          THEN to_jsonb(regexp_replace(e.value #>> '{}', '#{pattern}', '#{replacement}', 'g'))
          ELSE e.value
        END
      )
      FROM jsonb_each(html_body) AS e
    )
    WHERE jsonb_typeof(html_body) = 'object'
      AND EXISTS (
        SELECT 1 FROM jsonb_each(html_body) AS e
        WHERE jsonb_typeof(e.value) = 'string' AND (e.value #>> '{}') ~ '#{pattern}'
      )\
    """
  end

  defp marker_statement(version) do
    "COMMENT ON TABLE #{@schema_token}.#{@version_table} IS '#{@marker_prefix}#{version}'"
  end

  defp target_version(opts) when is_list(opts),
    do: Keyword.get(opts, :version, @current_version)

  defp target_version(_opts), do: @current_version

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the legal chain uses.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
