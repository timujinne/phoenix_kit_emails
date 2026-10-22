defmodule PhoenixKit.Modules.Emails.Verification.JsonList do
  @moduledoc """
  An Ecto type for a `jsonb` column that holds a JSON *array*.

  Ecto's `:map` refuses a list and `{:array, :map}` means Postgres `jsonb[]`, a
  different column type; this passes the list through to the `jsonb` column
  unchanged.
  """

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_other), do: :error

  @impl true
  def load(list) when is_list(list), do: {:ok, list}
  def load(_other), do: :error

  @impl true
  def dump(list) when is_list(list), do: {:ok, list}
  def dump(_other), do: :error
end
