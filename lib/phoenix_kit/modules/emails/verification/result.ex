defmodule PhoenixKit.Modules.Emails.Verification.Result do
  @moduledoc """
  The verdict on one address, and the row that stores the latest one
  (`phoenix_kit_email_verifications`, one row per address).

  ## Fields

    * `status` - `"valid" | "invalid" | "temp" | "not_sure"`. Only an SMTP probe
      can produce `"valid"`.
    * `reason` - why: `"syntax"`, `"bad_tld"`, `"disposable"`, `"no_mx"`,
      `"dns_error"`, `"smtp_disabled"`, `"smtp_unavailable"`,
      `"job_failed"` (a batch job gave up on the address; `level` is `nil`), ...
    * `level` - how far the pipeline got: `"syntax" | "dict" | "mx" | "smtp"`.
      An address that passed every step without SMTP is `"not_sure"` at `"mx"`:
      the domain takes mail, the mailbox is unchecked.
    * `catch_all` - `true`/`false` once an SMTP probe has said, otherwise `nil`.
    * `free`, `role`, `disposable` - flags; they never decide the verdict by
      themselves, except `disposable`, which is also the `"disposable"` reason.
    * `fake`, `curse`, `typo` - flags that never decide anything (see
      `Verification.Flags`); stored for a later UI, shown nowhere yet.
    * `mx` - the preferred mail host, when the domain resolved.
    * `log` - the steps that ran, each `%{"step", "outcome", "ms", ...}`.
    * `checked_at` - when the pipeline ran.
    * `source` (not stored) - `"direct"` for a verdict just computed,
      `"cache"` for one read back from the table.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Modules.Emails.Verification.JsonList

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @statuses ~w(valid invalid temp not_sure)
  @levels ~w(syntax dict mx smtp)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_email_verifications" do
    field(:email, :string)
    field(:domain, :string)
    field(:status, :string)
    field(:reason, :string)
    field(:level, :string)
    field(:catch_all, :boolean)
    field(:free, :boolean, default: false)
    field(:role, :boolean, default: false)
    field(:disposable, :boolean, default: false)
    field(:fake, :boolean, default: false)
    field(:curse, :boolean, default: false)
    field(:typo, :boolean, default: false)
    field(:mx, :string)
    field(:log, JsonList, default: [])
    field(:attempts, :integer, default: 1)
    field(:checked_at, :utc_datetime)
    field(:source, :string, virtual: true, default: "direct")

    timestamps(type: :utc_datetime)
  end

  @doc "The statuses a verdict can have."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The pipeline levels a verdict can stop at."
  @spec levels() :: [String.t()]
  def levels, do: @levels

  @fields ~w(email domain status reason level catch_all free role disposable fake curse typo mx log attempts checked_at)a

  @doc false
  def changeset(result, attrs) do
    result
    |> cast(attrs, @fields)
    |> validate_required([:email, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:level, @levels)
    |> validate_length(:domain, max: 255)
    |> validate_length(:mx, max: 255)
    |> validate_length(:reason, max: 64)
  end
end
