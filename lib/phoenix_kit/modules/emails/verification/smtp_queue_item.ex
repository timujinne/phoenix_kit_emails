defmodule PhoenixKit.Modules.Emails.Verification.SmtpQueueItem do
  @moduledoc """
  One address waiting for an SMTP session (`phoenix_kit_email_verify_smtp_queue`).

  ## Fields

    * `email` - the address the verdict is stored under
    * `checked_as` - the address the mail host is asked about (the `+tag` cut off)
    * `domain` - its domain; a session covers one domain
    * `state` - `"queued"`, `"leased"` (a runner holds it), `"done"` or `"cancelled"`.
      An address is `queued` or `leased` at most once (a unique partial index).
    * `attempts` - sessions that ended without a verdict: an expired lease, a
      greylist, a failed connection
    * `not_before` - the queue does not hand it out earlier (retry waits)
    * `lease_token`, `leased_by`, `lease_expires_at` - the session that holds it:
      one token per session, `leased_by` the runner's uuid (or `"local"`)
    * `last_reason` - why the last attempt did not settle it
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "phoenix_kit_email_verify_smtp_queue" do
    field(:email, :string)
    field(:checked_as, :string)
    field(:domain, :string)
    field(:state, :string, default: "queued")
    field(:attempts, :integer, default: 0)
    field(:not_before, :utc_datetime)
    field(:lease_token, :string)
    field(:leased_by, :string)
    field(:lease_expires_at, :utc_datetime)
    field(:last_reason, :string)

    timestamps(type: :utc_datetime)
  end
end
