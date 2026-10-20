defmodule PhoenixKit.Modules.Emails.Verification.Runner do
  @moduledoc """
  A runner that has connected (`phoenix_kit_email_verify_runners`): one row per API
  key, written by every `claim` call (the heartbeat).

  ## Fields

    * `api_key_uuid` - the key the runner authenticates with
    * `name`, `version`, `os`, `helo_auto` - what the runner says about itself
    * `public_ip` - the address the server saw the request come from
    * `port25` - `"open"`, `"blocked"` or `"unknown"`, from the runner's self-test;
      `port25_checked_at` is when it last said
    * `last_seen_at` - the last heartbeat
    * `jobs_done` - addresses settled by this runner's reports
    * `last_error` - why the last failing session failed
    * `paused_until`, `pause_reason` - the autopause; while set `claim` hands out nothing
    * `fail_streak`, `fail_domains` - the state of that autopause: sessions that failed
      in a row, and the domains they hit
    * `updated_at` - also the time of the last announcement on the PubSub topic (a
      heartbeat is announced at most every 5 seconds); see `Verification.Runners`
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Modules.Emails.Verification.JsonList

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @port25_values ~w(open blocked unknown)

  @type t :: %__MODULE__{}

  schema "phoenix_kit_email_verify_runners" do
    field(:api_key_uuid, Ecto.UUID)
    field(:name, :string)
    field(:version, :string)
    field(:os, :string)
    field(:public_ip, :string)
    field(:helo_auto, :string)
    field(:port25, :string, default: "unknown")
    field(:port25_checked_at, :utc_datetime)
    field(:last_seen_at, :utc_datetime)
    field(:jobs_done, :integer, default: 0)
    field(:last_error, :string)
    field(:paused_until, :utc_datetime)
    field(:pause_reason, :string)
    field(:fail_streak, :integer, default: 0)
    field(:fail_domains, JsonList, default: [])

    timestamps(type: :utc_datetime)
  end

  @doc "The values `port25` can take."
  @spec port25_values() :: [String.t()]
  def port25_values, do: @port25_values
end
