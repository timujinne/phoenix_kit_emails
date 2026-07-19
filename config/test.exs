import Config

# Embedded test repo for library-level integration tests (mirrors core
# phoenix_kit's config/test.exs). B2/B4 need real Integrations/Settings
# DB round-trips, which this package had no test DB for until now.
config :phoenix_kit_emails, ecto_repos: [PhoenixKitEmails.Test.Repo]

config :phoenix_kit_emails, PhoenixKitEmails.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_emails_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

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
