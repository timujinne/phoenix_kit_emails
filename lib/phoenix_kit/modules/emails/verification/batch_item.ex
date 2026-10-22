defmodule PhoenixKit.Modules.Emails.Verification.BatchItem do
  @moduledoc """
  One address of a batch (`phoenix_kit_email_verify_batch_items`), unique per
  batch.

  `state` is `"pending"` until the address has been verified and counted into
  its batch, then `"done"`. An address that passed the MX step with SMTP on is
  `"awaiting_smtp"` in between: it waits in the SMTP queue and is counted when its
  final verdict lands. `next_attempt_at` is set while a retry is waiting
  (a failed DNS lookup, a greylisted address) and cleared when the item is done.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_email_verify_batch_items" do
    field(:batch_uuid, Ecto.UUID)
    field(:email, :string)
    field(:state, :string, default: "pending")
    field(:next_attempt_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end
end
