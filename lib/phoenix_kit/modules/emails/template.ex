defmodule PhoenixKit.Modules.Emails.Template do
  @moduledoc """
  Email template schema for managing reusable email templates.

  This module defines the structure and validations for email templates that can be
  used throughout the application. Templates support variable substitution and
  categorization for better organization.

  ## Template Variables

  Templates support variable substitution using the `{{variable_name}}` syntax.
  Common variables include:

  - `{{email}}` - User's email address
  - `{{url}}` - Action URL (magic link, confirmation, etc.)
  - `{{timestamp}}` - Current timestamp
  - `{{user_name}}` - User's display name

  ## Categories

  - **system** - Core authentication and system emails (protected)
  - **marketing** - Promotional and marketing communications
  - **transactional** - Order confirmations, notifications, etc.
  - **notification** - Event-driven notifications (new posts, comments, etc.)

  ## Source Modules

  Templates can be tagged with a source module in the `metadata` field to track
  which part of the application sends the email:

  - **users** - User management (magic_link, password_reset, email_confirmation)
  - **billing** - Billing module (invoices, receipts, payment notifications)
  - **publishing** - Publishing module (new posts, comments)
  - **entities** - Entities module (entity notifications)
  - **admin** - Admin functions (test emails, manual sends)
  - **custom** - Custom/user-defined emails

  ## Metadata Structure

  The `metadata` field can contain:

      %{
        "source_module" => "users",    # Source module identifier
        "priority" => "high",           # Email priority (optional)
        "requires_user" => true         # Whether user_uuid is required (optional)
      }

  ## Status

  - **active** - Template is live and can be used
  - **draft** - Template is being edited
  - **archived** - Template is no longer active but preserved

  ## Examples

      # Create a new template
      %EmailTemplate{}
      |> EmailTemplate.changeset(%{
        name: "welcome_email",
        slug: "welcome-email",
        display_name: "Welcome Email",
        subject: "Welcome to {{app_name}}!",
        html_body: "<h1>Welcome {{user_name}}!</h1>",
        text_body: "Welcome {{user_name}}!",
        category: "transactional",
        status: "active"
      })

  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{
          name: String.t(),
          slug: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t(),
          category: String.t(),
          status: String.t(),
          variables: map(),
          metadata: map(),
          usage_count: integer(),
          last_used_at: DateTime.t() | nil,
          version: integer(),
          is_system: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Valid categories for email templates
  @valid_categories ["system", "marketing", "transactional", "notification", "newsletters"]

  # Valid statuses for email templates
  @valid_statuses ["active", "draft", "archived"]

  # Valid source modules for email templates
  @valid_source_modules ["users", "billing", "publishing", "entities", "admin", "custom"]

  # Common template variables that can be used
  @common_variables [
    "email",
    "user_name",
    "url",
    "timestamp",
    "app_name",
    "support_email",
    "company_name"
  ]

  # Template names that `PhoenixKit.Email.Content.resolve/5` looks up by exact
  # string at its layer 1 (an active DB row wins over the file override and the
  # gettext-embedded default). Source of truth is core's `user_notifier.ex` /
  # `mailer.ex` and `phoenix_kit_billing`'s call sites — not this package's own
  # seed list — since that's how the un-seeded four below were found.
  @reserved_names [
    # Seeded by this package's default_system_templates/0 — already have a
    # unique-constrained DB row on every install that ran the seed.
    "magic_link",
    "register",
    "reset_password",
    "update_email",
    "test_email",
    "billing_invoice",
    "billing_receipt",
    "billing_credit_note",
    "billing_payment_confirmation",
    # Called by core's user_notifier.ex but NOT seeded by this package — no DB
    # row exists on a fresh install, so a non-system template created through
    # the ordinary "New Template" form can hijack one of these today.
    "organization_invitation",
    "magic_link_registration",
    "new_login_alert",
    "failed_login_alert"
  ]

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_email_templates" do
    field(:name, :string)
    field(:slug, :string)
    field(:display_name, :map, default: %{})
    field(:description, :map, default: nil)
    field(:subject, :map, default: %{})
    field(:html_body, :map, default: %{})
    field(:text_body, :map, default: %{})
    field(:category, :string, default: "transactional")
    field(:status, :string, default: "draft")
    field(:variables, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:usage_count, :integer, default: 0)
    field(:last_used_at, :utc_datetime)
    field(:version, :integer, default: 1)
    field(:is_system, :boolean, default: false)
    field(:created_by_user_uuid, UUIDv7)
    field(:updated_by_user_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of valid categories for email templates.
  """
  def valid_categories, do: @valid_categories

  @doc """
  Returns the list of valid statuses for email templates.
  """
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns the list of common template variables.
  """
  def common_variables, do: @common_variables

  @doc """
  Returns the list of template names reserved for system emails.

  A non-system row (`is_system: false`) claiming one of these names would win
  at `PhoenixKit.Email.Content.resolve/5`'s layer 1 with none of the
  protections a seeded `is_system: true` row gets: it is not delete-protected
  and not flagged as a system template in the UI, yet it silently overrides
  the real email's content. The changeset rejects creating or renaming a
  non-system template into one of these names.
  """
  def reserved_names, do: @reserved_names

  @doc """
  Extracts a translated string from a JSON language map field.

  ## Parameters
  - `field_map` — a map like `%{"en" => "...", "uk" => "..."}`
  - `locale` — the desired locale code, e.g. `"uk"` or `"en-US"`
  - `default_locale` — fallback locale, defaults to `"en"`

  ## Behaviour
  1. Try exact match: `field_map[locale]`
  2. Try base language: e.g. `"en"` from `"en-US"`
  3. Try default_locale
  4. Try any available value (last resort)
  5. Return `""` if map is empty or nil

  ## Examples

      iex> get_translation(%{"en" => "Hello", "uk" => "Привіт"}, "uk")
      "Привіт"

      iex> get_translation(%{"en" => "Hello"}, "uk")
      "Hello"

      iex> get_translation(nil, "uk")
      ""

  """
  def get_translation(field_map, locale, default_locale \\ "en")

  def get_translation(nil, _locale, _default_locale), do: ""

  def get_translation(field_map, locale, default_locale) when is_map(field_map) do
    base_locale = locale |> String.split("-") |> List.first()

    Map.get(field_map, locale) ||
      Map.get(field_map, base_locale) ||
      Map.get(field_map, default_locale) ||
      field_map |> Map.values() |> List.first() ||
      ""
  end

  def get_translation(_field_map, _locale, _default_locale), do: ""

  @doc """
  Returns the list of valid source modules for email templates.
  """
  def valid_source_modules, do: @valid_source_modules

  @doc """
  Gets the source module from a template's metadata.

  Returns the source_module value if present, otherwise "custom".

  ## Examples

      iex> template = %EmailTemplate{metadata: %{"source_module" => "auth"}}
      iex> EmailTemplate.get_source_module(template)
      "auth"

      iex> template = %EmailTemplate{metadata: %{}}
      iex> EmailTemplate.get_source_module(template)
      "custom"

  """
  def get_source_module(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "source_module", "custom")
  end

  def get_source_module(_), do: "custom"

  @doc """
  Sets the source module in a template's metadata.

  Returns updated metadata map with source_module set.

  ## Examples

      iex> EmailTemplate.set_source_module(%{}, "auth")
      %{"source_module" => "auth"}

  """
  def set_source_module(metadata, source_module)
      when is_map(metadata) and source_module in @valid_source_modules do
    Map.put(metadata, "source_module", source_module)
  end

  def set_source_module(metadata, _source_module), do: metadata

  @doc """
  Creates a changeset for email template creation and updates.

  ## Parameters

  - `template` - The email template struct (new or existing)
  - `attrs` - Map of attributes to change
  - `is_system` - Whether to (re)declare the row as a protected system
    template. **Not** read from `attrs` — `:is_system` is never cast from
    caller-supplied params, since `attrs` on the create/update paths used by
    the admin UI is untrusted client input (a crafted LiveView event can
    contain any key, not just what the rendered form submits). Pass `true`
    only from a call site that itself decides a row is a system template
    (currently only `Templates.seed_system_templates/0`); leave the default
    `nil` everywhere else, which keeps the existing/new struct's current
    value unchanged.

  ## Required Fields

  - `:name` - Unique template identifier
  - `:slug` - URL-friendly identifier
  - `:display_name` - Human-readable name
  - `:subject` - Email subject line
  - `:html_body` - HTML version of email
  - `:text_body` - Plain text version of email

  ## Validations

  - Name must be unique and follow snake_case format
  - Slug must be unique and URL-friendly
  - Category must be one of the valid categories
  - Status must be one of the valid statuses
  - Subject and body fields cannot be empty
  - Variables must be a valid map
  """
  def changeset(template, attrs, is_system \\ nil) do
    template
    |> cast(attrs, [
      :name,
      :slug,
      :display_name,
      :description,
      :subject,
      :html_body,
      :text_body,
      :category,
      :status,
      :variables,
      :metadata,
      :created_by_user_uuid,
      :updated_by_user_uuid
    ])
    |> put_is_system(is_system)
    |> auto_generate_slug()
    |> validate_required([
      :name,
      :slug,
      :display_name,
      :subject,
      :html_body,
      :text_body,
      :category,
      :status
    ])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:slug, min: 2, max: 100)
    |> validate_i18n_map(:display_name, min_length: 2, max_length: 200)
    |> validate_i18n_map(:subject, min_length: 1, max_length: 300)
    |> validate_i18n_map(:html_body, min_length: 1)
    |> validate_i18n_map(:text_body, min_length: 1)
    |> validate_inclusion(:category, @valid_categories)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a letter and contain only lowercase letters, numbers, and underscores"
    )
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]*$/,
      message: "must start with a letter and contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> validate_template_variables()
    |> validate_reserved_name()
  end

  @doc """
  Creates a changeset for updating template usage statistics.
  """
  def usage_changeset(template, attrs \\ %{}) do
    template
    |> cast(attrs, [:usage_count, :last_used_at])
    |> validate_number(:usage_count, greater_than_or_equal_to: 0)
  end

  @doc """
  Creates a changeset for updating template version.
  """
  def version_changeset(template, attrs \\ %{}) do
    template
    |> cast(attrs, [:version, :updated_by_user_uuid])
    |> validate_number(:version, greater_than: 0)
  end

  @doc """
  Extracts variables from template content (subject, html_body, text_body).

  Returns a list of unique variable names found in the template.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: "Welcome {{user_name}}!",
      ...>   html_body: "<p>Hi {{user_name}}, click {{url}}</p>",
      ...>   text_body: "Hi {{user_name}}, visit {{url}}"
      ...> }
      iex> EmailTemplate.extract_variables(template)
      ["user_name", "url"]

  """
  def extract_variables(%__MODULE__{} = template) do
    # Collect all language values from all map fields and scan for {{variables}}
    content =
      [template.subject, template.html_body, template.text_body]
      |> Enum.flat_map(fn
        map when is_map(map) -> Map.values(map)
        str when is_binary(str) -> [str]
        _ -> []
      end)
      |> Enum.join(" ")

    Regex.scan(~r/\{\{([^}]+)\}\}/, content)
    |> Enum.map(fn [_, var] -> String.trim(var) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Substitutes variables in template content with provided values.

  ## Parameters

  - `template` - The email template
  - `variables` - Map of variable names to values
  - `locale` - The target locale code (default: `"en"`)

  Returns a map `%{subject: string, html_body: string, text_body: string}` with
  the locale-specific content and all variables substituted.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: %{"en" => "Welcome {{user_name}}!"},
      ...>   html_body: %{"en" => "<p>Hi {{user_name}}</p>"},
      ...>   text_body: %{"en" => "Hi {{user_name}}"}
      ...> }
      iex> result = EmailTemplate.substitute_variables(template, %{"user_name" => "John"}, "en")
      iex> result.subject
      "Welcome John!"

  """
  def substitute_variables(%__MODULE__{} = template, variables, locale \\ "en")
      when is_map(variables) do
    %{
      subject: template.subject |> get_translation(locale) |> substitute_string(variables),
      html_body: template.html_body |> get_translation(locale) |> substitute_string(variables),
      text_body: template.text_body |> get_translation(locale) |> substitute_string(variables)
    }
  end

  # Private helper functions

  # Validates that a :map field contains valid language-keyed string values
  defp validate_i18n_map(changeset, field, opts) do
    case get_field(changeset, field) do
      nil ->
        changeset

      map when is_map(map) and map_size(map) == 0 ->
        add_error(changeset, field, "must have at least one language")

      map when is_map(map) ->
        validate_i18n_map_values(changeset, field, map, opts)

      _ ->
        add_error(changeset, field, "must be a language map (e.g. %{\"en\" => \"...\"})")
    end
  end

  defp validate_i18n_map_values(changeset, field, map, opts) do
    min_length = Keyword.get(opts, :min_length, 0)
    max_length = Keyword.get(opts, :max_length, nil)

    errors =
      Enum.flat_map(map, fn {lang, value} ->
        i18n_value_errors(lang, value, min_length, max_length)
      end)

    case errors do
      [] -> changeset
      msgs -> add_error(changeset, field, Enum.join(msgs, "; "))
    end
  end

  defp i18n_value_errors(lang, value, min_length, max_length) do
    cond do
      not is_binary(value) ->
        ["#{lang}: must be a string"]

      String.length(value) < min_length ->
        ["#{lang}: must be at least #{min_length} characters"]

      max_length != nil and String.length(value) > max_length ->
        ["#{lang}: must be at most #{max_length} characters"]

      true ->
        []
    end
  end

  # Automatically generate slug from name if not provided
  defp auto_generate_slug(changeset) do
    slug = get_change(changeset, :slug) || get_field(changeset, :slug)

    case slug do
      s when s in [nil, ""] ->
        name = get_change(changeset, :name) || get_field(changeset, :name)

        case name do
          n when is_binary(n) and n != "" ->
            put_change(changeset, :slug, String.replace(n, "_", "-"))

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  # Validate that template variables are correctly formatted
  defp validate_template_variables(changeset) do
    case get_field(changeset, :variables) do
      nil ->
        changeset

      variables when is_map(variables) ->
        # Extract variables from template content and validate against declared variables
        subject = get_field(changeset, :subject)
        html_body = get_field(changeset, :html_body)
        text_body = get_field(changeset, :text_body)

        if subject != nil and html_body != nil and text_body != nil do
          template = %__MODULE__{
            subject: subject,
            html_body: html_body,
            text_body: text_body
          }

          extracted_vars = extract_variables(template)
          declared_vars = Map.keys(variables)

          # Check for undefined variables in template
          undefined_vars = extracted_vars -- declared_vars

          if Enum.empty?(undefined_vars) do
            changeset
          else
            add_error(
              changeset,
              :variables,
              "Template uses undefined variables: #{Enum.join(undefined_vars, ", ")}"
            )
          end
        else
          changeset
        end

      _ ->
        add_error(changeset, :variables, "must be a valid map")
    end
  end

  # Blocks a non-system row from claiming a reserved name — creation via the
  # "New Template" form (never sends is_system, defaults false),
  # Templates.clone_template/3 (forces is_system: false), and renaming an
  # existing non-system template into a reserved name. Gating on
  # `is_system != true` (rather than "name already exists") still allows
  # Templates.seed_system_templates/0 to create/reseed these rows and allows
  # editing an existing system row, since its persisted is_system: true
  # carries through get_field/2 even when attrs omits the key.
  #
  # Only fires when :name or :is_system is actually part of this change.
  # Without that guard, a row that already exists with a reserved name (e.g.
  # a hijack created before this validation shipped) could never be archived,
  # edited or otherwise remediated again — every unrelated update (status,
  # subject, ...) would also re-run this check against the untouched name and
  # fail, since it wasn't gated on what changed.
  defp validate_reserved_name(changeset) do
    if changed?(changeset, :name) or changed?(changeset, :is_system) do
      name = get_field(changeset, :name)
      is_system = get_field(changeset, :is_system)

      if name in @reserved_names and is_system != true do
        add_error(changeset, :name, "is reserved for a system email")
      else
        changeset
      end
    else
      changeset
    end
  end

  # `is_system` is never cast from `attrs` (see `changeset/2` doc) — this is
  # the only way it can change, and only a call site that passes a literal
  # boolean can invoke it.
  defp put_is_system(changeset, nil), do: changeset

  defp put_is_system(changeset, is_system) when is_boolean(is_system) do
    put_change(changeset, :is_system, is_system)
  end

  # Substitute variables in a string
  defp substitute_string(content, variables) when is_binary(content) and is_map(variables) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp substitute_string(content, _variables), do: content
end
