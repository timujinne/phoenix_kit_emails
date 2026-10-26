defmodule PhoenixKit.Modules.Emails.MigrationsBuildAloneTest do
  @moduledoc """
  This package's chain builds all of its email tables exactly as core's chain
  does, on a database where core did not create them — the proof core needs
  before it stops creating them (core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`). Rows are not
  compared: core's chain seeds none of these tables (the system templates are
  seeded at runtime by this package).

  `PhoenixKit.TestSupport.ModuleChainCheck` does the work in a scratch schema
  of its own, through `Ecto.Migrator` — so `ExUnit.Case`, not a sandboxed case,
  and `async: false`. Excluded (`:requires_module_chain_check`, see
  `test_helper.exs`) against a core that does not ship the check yet.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKit.TestSupport.ModuleChainCheck
  alias PhoenixKitEmails.Test.Repo

  @moduletag :integration
  @moduletag :requires_module_chain_check
  @moduletag timeout: :timer.minutes(3)

  test "the chain builds the email tables without core" do
    assert :ok = ModuleChainCheck.check(Repo, Migrations)
  end
end
