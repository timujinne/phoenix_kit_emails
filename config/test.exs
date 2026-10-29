import Config

# Embedded test repo for library-level integration tests (mirrors core
# phoenix_kit's config/test.exs). B2/B4 need real Integrations/Settings
# DB round-trips, which this package had no test DB for until now.
config :phoenix_kit_emails, ecto_repos: [PhoenixKitEmails.Test.Repo]

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (e.g. a shared instance) instead of the name Hex CI
# provisions for itself. Same mechanism as core phoenix_kit's
# config/test.exs — see there for the full rationale. Left unset (CI's
# case), this falls back to the previous hardcoded name, so publishing
# and CI are unaffected. Both repo configs below share this — same physical
# database, see the MigrationRepo comment.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_emails_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

# `PGPOOL` bounds the connection pool the same way core does — the default
# (`schedulers_online() * 2`) opens dozens of connections on a many-core
# box, which is fine against a private local Postgres but not against a
# shared instance already near its connection ceiling.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_emails, PhoenixKitEmails.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# Same database, ordinary pool — for the one test that drives a real
# Ecto.Migrator (see PhoenixKitEmails.Test.MigrationRepo).
config :phoenix_kit_emails, PhoenixKitEmails.Test.MigrationRepo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool_size: 2

# Wire the repo for phoenix_kit library code that calls
# PhoenixKit.Config.get_repo/0 (Settings, Integrations, etc).
config :phoenix_kit, repo: PhoenixKitEmails.Test.Repo

config :logger, level: :warning

# Integrations credentials (e.g. the AWS SES secret_key migrated by
# Emails.migrate_legacy/0) are only encrypted at rest when a
# secret_key_base is configured — set one so B4's tests can assert the
# real enc:v1: round-trip instead of a no-op passthrough.
config :phoenix_kit,
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_kit_emails_tests"

# BrevoPollingJob must never hit the real Brevo API in tests. The stub
# name is constant (not set per-test) — Req.Test's own ownership model
# scopes stub *behavior* per calling process, so this single global value
# is safe under `async: true`; only the registered stub function (set via
# `Req.Test.stub/2` inside each test) actually varies.
config :phoenix_kit_emails,
  brevo_client_req_options: [plug: {Req.Test, PhoenixKit.Modules.Emails.BrevoPollingJobTest.Stub}]
