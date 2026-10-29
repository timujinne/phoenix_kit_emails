defmodule PhoenixKit.Modules.Emails.Template do
  @moduledoc """
  The legacy email-template row, read-only.

  Email templates are files now (`phoenix_kit_templates` overrides over the
  defaults core and each module ship); the `phoenix_kit_email_templates` table
  is retired and no longer created. This schema survives for one reason: hosts
  upgraded from core 2.x still hold the rows they edited, and
  `mix phoenix_kit_emails.templates.export` (via `PhoenixKit.Modules.Emails.TemplateExport`)
  reads them with it to write those edits out as files. Nothing here writes a row.

  The placeholder syntax of a stored body is `{{name}}` (HTML-escaped in the
  `html` part) or `{{{name}}}` (raw); `placeholder_regex/0` is the one pattern.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

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

  @raw_html_variables ["line_items_html", "line_items_table_html"]

  @doc """
  Returns template variables whose value is already-rendered HTML rather than
  plain text.

  `phoenix_kit_billing` builds both from escaped line items and hands them to
  this package ready to insert: `line_items_html` is a run of `<tr>...</tr>`
  rows, `line_items_table_html` a whole `<table>`. Since `{{var}}` is
  HTML-escaped in `html_body` (core's substitution), content must
  write these as `{{{var}}}` — the raw form.

  The list is read by `TemplateExport`, which rewrites them for
  `phoenix_kit_templates` files. (This package's V3 migration, which rewrote
  `{{var}}` to `{{{var}}}` in every stored `html_body`, uses a frozen copy.)

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
end
