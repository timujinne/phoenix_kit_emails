defmodule PhoenixKit.Modules.Emails.Verification.Batch do
  @moduledoc """
  A batch: one request to verify a list of addresses
  (`phoenix_kit_email_verify_batches`).

  ## Fields

    * `source_type` - who asked: `"newsletters_crm_list"`, `"newsletters_user_group"`,
      `"crm_list"`, `"crm_contacts"` or `"manual"`.
    * `source_ref` - the consumer's own handle (a list uuid, ...), or `nil`.
    * `state` - `"queued"` (stored, items not laid out yet), `"running"`,
      `"done"` or `"cancelled"`.
    * `total` - addresses in the batch after normalising and deduplicating.
    * `processed` - addresses finished so far. `processed == total` is what makes
      the batch `"done"`.
    * `counts` - finished addresses by verdict status, e.g.
      `%{"not_sure" => 3, "invalid" => 1}`; a status nobody got is absent.
    * `awaiting_smtp` - addresses that passed the MX step and wait for their SMTP
      result. They are not in `processed` yet: an address counts as processed when
      its final verdict lands, and the batch is `"done"` only then.
    * `started_at` / `finished_at` - when the items were laid out, and when the
      batch ended (done or cancelled).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @source_types ~w(newsletters_crm_list newsletters_user_group crm_list crm_contacts manual)
  @states ~w(queued running done cancelled)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_email_verify_batches" do
    field(:source_type, :string)
    field(:source_ref, :string)
    field(:title, :string)
    field(:state, :string, default: "queued")
    field(:total, :integer, default: 0)
    field(:processed, :integer, default: 0)
    field(:counts, :map, default: %{})
    field(:awaiting_smtp, :integer, default: 0)
    field(:created_by_uuid, Ecto.UUID)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)

    # Microseconds: batches of one source are listed newest first, and two can be
    # started within the same second.
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The values `source_type` can take."
  @spec source_types() :: [String.t()]
  def source_types, do: @source_types

  @doc "The values `state` can take."
  @spec states() :: [String.t()]
  def states, do: @states

  @fields ~w(source_type source_ref title total created_by_uuid)a

  @doc false
  def create_changeset(batch, attrs) do
    batch
    |> cast(attrs, @fields)
    |> validate_required([:source_type, :total])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_number(:total, greater_than: 0)
    |> validate_length(:source_ref, max: 255)
    |> validate_length(:title, max: 255)
    |> validate_storable(:source_ref)
    |> validate_storable(:title)
  end

  @doc false
  # Text Postgres can hold: valid UTF-8 without a NUL byte.
  @spec storable?(term()) :: boolean()
  def storable?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def storable?(_value), do: false

  defp validate_storable(changeset, field) do
    validate_change(changeset, field, fn _field, value ->
      if storable?(value), do: [], else: [{field, "contains characters that cannot be stored"}]
    end)
  end
end
