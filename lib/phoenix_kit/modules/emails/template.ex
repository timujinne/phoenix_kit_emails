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

  @raw_html_variables ["line_items_html", "line_items_table_html"]

  @doc """
  Returns template variables whose value is already-rendered HTML rather than
  plain text.

  `phoenix_kit_billing` builds both from escaped line items and hands them to
  this package ready to insert: `line_items_html` is a run of `<tr>...</tr>`
  rows, `line_items_table_html` a whole `<table>`. Since `{{var}}` is
  HTML-escaped in `html_body` (see `substitute_variables/3`), content must
  write these as `{{{var}}}` — the raw form.

  The list is read in three places:

    * `PhoenixKit.Modules.Emails.Migrations` V3 rewrites `{{var}}` to
      `{{{var}}}` in every stored `html_body`;
    * `substitute_variables/3` inserts these names raw even when written
      with double braces, so a row the migration has not reached yet (the
      code deployed before `mix phoenix_kit.update` ran, a restored backup)
      still sends a table and not escaped markup;
    * `TemplateExport` rewrites them for `phoenix_kit_templates` files.

  `content` on operator-authored newsletters is deliberately absent:
  `phoenix_kit_newsletters`'s `DeliveryWorker.compose_html/3` substitutes it
  with its own `String.replace/3` and never calls this module, so nothing
  here escapes it.

  A name belongs on the list by being listed here, not by any naming
  convention — `TemplateExport.rewrite_raw_html/3`'s `_html`-suffix check is
  a separate, looser heuristic it falls back to only for flagging a name that
  *isn't* on this list.
  """
  def raw_html_variables, do: @raw_html_variables

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
  The text the editor shows for `locale`: what is stored for it, with no
  fallback, or `""`.

  `get_translation/3` answers "what should this reader see", and falls back
  to the base language, `"en"` and then any value. The editor needs the other
  question, "what is stored for this locale": an input filled from the
  fallback and then saved would write the fallback text into the locale as a
  translation of its own, and the fallback could no longer apply.

  One exception, for hosts whose languages carry a region (`"en-US"`) while
  the stored rows are keyed by the base code (`"en"`, as seeded): a tab with
  no key of its own shows the base key's text when `tabs` — every enabled
  locale, in tab order — makes that unambiguous. That is the first tab with
  that base code, and the base code is not a tab itself (it has its own key
  then). Saving writes the text under the tab's key. Without `tabs` the
  lookup is exact.

  ## Examples

      iex> stored_translation(%{"en" => "Hello"}, "en")
      "Hello"

      iex> stored_translation(%{"en" => "Hello"}, "et")
      ""

      iex> stored_translation(%{"en" => "Hello"}, "en-US", ["en-US", "en-GB"])
      "Hello"

      iex> stored_translation(%{"en" => "Hello"}, "en-GB", ["en-US", "en-GB"])
      ""

  """
  @spec stored_translation(term(), String.t(), [String.t()]) :: String.t()
  def stored_translation(field_map, locale, tabs \\ [])

  def stored_translation(field_map, locale, tabs) when is_map(field_map) do
    case Map.fetch(field_map, locale) do
      {:ok, value} -> text_or_empty(value)
      :error -> field_map |> inherited_translation(locale, tabs)
    end
  end

  def stored_translation(_field_map, _locale, _tabs), do: ""

  defp inherited_translation(field_map, locale, tabs) do
    base = base_code(locale)

    if base != locale and base not in tabs and locale == Enum.find(tabs, &(base_code(&1) == base)) do
      field_map |> Map.get(base) |> text_or_empty()
    else
      ""
    end
  end

  defp base_code(locale), do: locale |> String.split("-") |> List.first()

  defp text_or_empty(value) when is_binary(value), do: value
  defp text_or_empty(_value), do: ""

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
  - Subject and body fields need text in at least one language
  - Variables must be a valid map

  ## Translations

  A locale whose text is empty (or only whitespace) is not a translation: it
  is dropped from `display_name`, `description`, `subject`, `html_body` and
  `text_body` before validation. The editor posts a key for every enabled
  language, so a template written in one language arrives with the others
  empty; what is required is one locale with text, not one per language.

  ## Metadata

  A submitted `metadata` is merged into the row's existing metadata, not
  substituted for it, so a form that carries only `source_module` cannot erase
  `cloned_from`. A key cannot be removed through this changeset. A submitted
  `source_module` must be one of `valid_source_modules/0`.

  ## Audit columns

  `created_by_user_uuid` and `updated_by_user_uuid` are not cast: attrs come
  from a form a client controls, and who made a change is for the context to
  say (`Templates.create_template/2`, `Templates.update_template/3`).
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
      :metadata
    ])
    |> merge_metadata()
    |> drop_empty_translations([:display_name, :description, :subject, :html_body, :text_body])
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
    |> validate_i18n_map(:description, allow_empty: true)
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
  Records who created the row on a changeset `changeset/3` built.

  For the context, which knows the author from the session — not for attrs a
  client sent. `nil` changes nothing; a value that is not a UUID is a
  changeset error, not a database one.
  """
  @spec put_created_by(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def put_created_by(changeset, nil), do: changeset

  def put_created_by(changeset, user_uuid) do
    cast(changeset, %{created_by_user_uuid: user_uuid}, [:created_by_user_uuid])
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

  # One tokenizer for reading and for substituting placeholders — the rules
  # of `PhoenixKit.Templates.Substitution` (`phoenix_kit_templates` >= 0.2.0),
  # so a database row and a file override read the same content the same way.
  # Not that module itself: this package supports cores that predate it.
  #
  # One combined, left-to-right pass. At any position after `{{`, the next
  # character settles which form can match: a third `{` only continues the
  # raw form, whitespace or a name only the escaped one. Two passes (double
  # first, then triple) would match the inner pair of `{{{x}}}` and leave
  # `{V}` behind. A name is an identifier; `{{user.name}}`, `{{a-b}}`, an
  # unclosed `{{x` and CSS braces are literal text.
  @placeholder ~r/
    \{\{\{\s*(?<triple>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}\}
    |
    \{\{\s*(?<double>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}
  /x

  @doc false
  # The one pattern, for the export task too: it has to tell `{{x}}` from
  # `{{{x}}}` and so reads the `triple` / `double` captures itself.
  @spec placeholder_regex() :: Regex.t()
  def placeholder_regex, do: @placeholder

  @doc """
  Extracts variables from template content (subject, html_body, text_body).

  Returns the sorted, unique names of every `{{name}}` and `{{{name}}}`
  placeholder in every locale of the three fields. Surrounding whitespace is
  not part of a name (`{{ name }}` is `name`), and anything that is not an
  identifier — `{{user.name}}`, `{{a b}}`, an unclosed `{{name` — is literal
  text, not a variable. `substitute_variables/3` reads placeholders with the
  same rules, so every name listed here is one it will substitute.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: "Welcome {{user_name}}!",
      ...>   html_body: "<p>Hi {{ user_name }}, click {{url}}</p>",
      ...>   text_body: "Hi {{user_name}}, visit {{{url}}}"
      ...> }
      iex> EmailTemplate.extract_variables(template)
      ["url", "user_name"]

  """
  def extract_variables(%__MODULE__{} = template) do
    [template.subject, template.html_body, template.text_body]
    |> Enum.flat_map(fn
      map when is_map(map) -> Map.values(map)
      str when is_binary(str) -> [str]
      _ -> []
    end)
    |> Enum.flat_map(&placeholder_names/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  # The placeholder names in one string, in order, with repeats. Shared with
  # `Templates.render_template/3`, which reports unbound ones.
  @spec placeholder_names(term()) :: [String.t()]
  def placeholder_names(content) when is_binary(content) do
    @placeholder
    |> Regex.scan(content)
    |> Enum.map(fn [_whole | groups] -> Enum.find(groups, &(&1 != "")) end)
  end

  def placeholder_names(_content), do: []

  @doc """
  Substitutes variables in template content with provided values.

  ## Parameters

  - `template` - The email template
  - `variables` - Map of variable names to values; atom and string keys are
    equivalent
  - `locale` - The target locale code (default: `"en"`)

  Returns a map `%{subject: string, html_body: string, text_body: string}` with
  the locale-specific content and all variables substituted.

  ## Escaping

  In `html_body`, a `{{name}}` value is HTML-escaped (`&` `<` `>` `"` `'`), so
  a customer name or a note cannot inject markup or break an attribute.
  `{{{name}}}` inserts the value raw, for a variable that already holds
  rendered HTML. The names on `raw_html_variables/0` are inserted raw in
  either form. `subject` and `text_body` are plain text and never escaped.

  ## Rules

  Placeholders are read as `extract_variables/1` reads them. An unbound
  placeholder is left exactly as written. A value is never itself scanned
  for placeholders.

  A value must be a string, a number, an atom (`true` is `"true"`, `nil` is
  `""`) or a struct implementing `String.Chars` (`Date`, `DateTime`,
  `Decimal`, ...). A map, list, tuple or any other value raises
  `ArgumentError` naming the variable, when a placeholder actually uses it.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: %{"en" => "Welcome {{user_name}}!"},
      ...>   html_body: %{"en" => "<p>Hi {{user_name}}</p>"},
      ...>   text_body: %{"en" => "Hi {{user_name}}"}
      ...> }
      iex> result = EmailTemplate.substitute_variables(template, %{"user_name" => "Tom & Jerry"}, "en")
      iex> result.subject
      "Welcome Tom & Jerry!"
      iex> result.html_body
      "<p>Hi Tom &amp; Jerry</p>"

  """
  def substitute_variables(%__MODULE__{} = template, variables, locale \\ "en")
      when is_map(variables) do
    variables = Map.new(variables, fn {key, value} -> {to_string(key), value} end)

    %{
      subject: template.subject |> get_translation(locale) |> substitute_string(variables, false),
      html_body:
        template.html_body |> get_translation(locale) |> substitute_string(variables, true),
      text_body:
        template.text_body |> get_translation(locale) |> substitute_string(variables, false)
    }
  end

  # Private helper functions

  # Submitted metadata is merged into the row's own, never substituted for it.
  # Only what was submitted is checked: a stored value that predates the check
  # is not this save's concern.
  defp merge_metadata(changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, submitted} when is_map(submitted) ->
        submitted = stringify_keys(submitted)
        merged = Map.merge(changeset.data.metadata || %{}, submitted)

        changeset
        |> put_change(:metadata, merged)
        |> validate_submitted_source_module(submitted)

      _ ->
        changeset
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp validate_submitted_source_module(changeset, %{"source_module" => source_module})
       when source_module not in @valid_source_modules do
    add_error(
      changeset,
      :metadata,
      "source_module must be one of: #{Enum.join(@valid_source_modules, ", ")}"
    )
  end

  defp validate_submitted_source_module(changeset, _submitted), do: changeset

  # A locale with no text is not a translation (see `changeset/3`). A value
  # that is not a string stays, so `validate_i18n_map/3` can name it.
  defp drop_empty_translations(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      update_change(acc, field, fn
        map when is_map(map) -> Map.reject(map, fn {_locale, value} -> blank_string?(value) end)
        other -> other
      end)
    end)
  end

  defp blank_string?(value), do: is_binary(value) and String.trim(value) == ""

  # Validates that a :map field contains valid language-keyed string values
  defp validate_i18n_map(changeset, field, opts) do
    case get_field(changeset, field) do
      nil ->
        changeset

      map when is_map(map) and map_size(map) == 0 ->
        if Keyword.get(opts, :allow_empty, false),
          do: changeset,
          else: add_error(changeset, field, "must have at least one language with text")

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

  # Substitute variables in a string, escaping `{{name}}` values when
  # `escape?` (the html_body). See `substitute_variables/3`.
  defp substitute_string(content, variables, escape?) when is_binary(content) do
    Regex.replace(@placeholder, content, fn whole, raw, escapable ->
      {name, raw?} = if raw != "", do: {raw, true}, else: {escapable, false}

      case Map.fetch(variables, name) do
        {:ok, value} ->
          value = scalar_to_string!(name, value)

          if escape? and not raw? and name not in @raw_html_variables,
            do: escape_html(value),
            else: value

        :error ->
          whole
      end
    end)
  end

  defp substitute_string(content, _variables, _escape?), do: content

  defp scalar_to_string!(_name, value) when is_binary(value), do: value

  defp scalar_to_string!(_name, value) when is_number(value) or is_atom(value),
    do: to_string(value)

  defp scalar_to_string!(name, %_{} = value) do
    if String.Chars.impl_for(value),
      do: to_string(value),
      else: raise_not_scalar(name, value)
  end

  defp scalar_to_string!(name, value), do: raise_not_scalar(name, value)

  # Names the kind of value, never the value: it may be a customer's data.
  defp raise_not_scalar(name, value) do
    kind =
      case value do
        %struct{} -> inspect(struct)
        map when is_map(map) -> "a map"
        list when is_list(list) -> "a list"
        tuple when is_tuple(tuple) -> "a tuple"
        _ -> "an unsupported value"
      end

    raise ArgumentError,
          "template variable #{inspect(name)} must be a string, number, atom or " <>
            "a struct implementing String.Chars (Date, Decimal, ...), got #{kind}"
  end

  defp escape_html(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
