defmodule PhoenixKitEmails.Test.LegacyTemplates do
  @moduledoc """
  The retired `phoenix_kit_email_templates` table, for the tests of the export
  that reads it.

  Nothing creates the table any more (not core 3.0, not this package's chain),
  so a test that needs rows builds it here, inside the sandbox transaction,
  where it is rolled back with everything else. The shape is the one hosts
  upgraded from core 2.x still have.
  """

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKitEmails.Test.Repo

  @doc "Creates the table (and nothing else) in the current transaction."
  @spec create_table!() :: :ok
  def create_table! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_email_templates (
      uuid uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
      name varchar(255) NOT NULL,
      slug varchar(255) NOT NULL,
      display_name jsonb NOT NULL,
      description jsonb,
      subject jsonb NOT NULL,
      html_body jsonb NOT NULL,
      text_body jsonb NOT NULL,
      category varchar(255) NOT NULL DEFAULT 'transactional',
      status varchar(255) NOT NULL DEFAULT 'draft',
      variables jsonb DEFAULT '{}'::jsonb,
      metadata jsonb DEFAULT '{}'::jsonb,
      usage_count integer NOT NULL DEFAULT 0,
      last_used_at timestamptz,
      version integer NOT NULL DEFAULT 1,
      is_system boolean NOT NULL DEFAULT false,
      created_by_user_uuid uuid,
      updated_by_user_uuid uuid,
      inserted_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """)

    :ok
  end

  @doc "Inserts every system template this package used to seed, as stored rows."
  @spec seed!() :: [Template.t()]
  def seed! do
    create_table!()

    for attrs <- Templates.default_system_templates() do
      Repo.insert!(struct(Template, Map.put(attrs, :is_system, true)))
    end
  end

  @doc "The stored row called `name`."
  @spec get!(String.t()) :: Template.t()
  def get!(name), do: Repo.get_by!(Template, name: name)

  @doc "Changes a stored row (`attrs` are field values, not params)."
  @spec update!(Template.t(), map()) :: Template.t()
  def update!(%Template{} = template, attrs) do
    template |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end
end
