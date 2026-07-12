defmodule PhoenixKitEmails.DataCase do
  @moduledoc """
  Setup for tests that touch the database (via core phoenix_kit's
  Settings/Integrations, backed by `PhoenixKitEmails.Test.Repo`).

  Mirrors core phoenix_kit's `PhoenixKit.DataCase`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEmails.Test.Repo

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
