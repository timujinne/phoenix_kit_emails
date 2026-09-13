defmodule PhoenixKit.Modules.Emails.TemplateExport do
  @moduledoc """
  Decides which stored templates become override files, and what those files
  are called.

  Message templates are moving from `phoenix_kit_email_templates` to files a
  host owns in its own repository. `plan/2` answers the two questions that
  migration turns on — *which rows carry an edit worth keeping*, and *what
  filename preserves the behaviour that row had* — as data, so
  `mix phoenix_kit_emails.templates.export` is left with nothing to do but
  write and report.

  ## Which rows

  | Row | Planned | Why |
  |---|---|---|
  | System template, edited | **yes** | the edit is the thing worth keeping |
  | System template, untouched | no | byte-identical to what this package ships; core supplies it now, translated |
  | Operator-authored (`is_system: false`) | no | newsletter layouts, authored at runtime — they keep a table and an editor |

  A template whose name this package does not ship counts as **edited**:
  nothing is known about what it should look like, and a file too many is
  recoverable where a dropped edit is not.

  ## Which filename

  The name becomes a directory and each part a file. The subtle part is the
  locale: a stored field is a language map, and `Template.get_translation/3`
  falls back through it, so one locale's content is what every recipient
  without their own translation actually receives. That locale must be written
  **without** a code in the filename, because a locale-less file is what core's
  resolution falls through to. Writing it as `subject.en.txt` would silently
  drop the operator's customization for every non-English recipient — the exact
  opposite of the point of exporting it.
  """

  alias PhoenixKit.Modules.Emails.Template

  @default_out "priv/phoenix_kit_templates"

  # Stored field -> {file stem, extension}. Only `html` is markup.
  @parts [{:subject, "subject", "txt"}, {:text_body, "text", "txt"}, {:html_body, "html", "html"}]

  @typedoc "What an export would do, without having done any of it."
  @type plan :: %{
          edited: [Template.t()],
          untouched: [Template.t()],
          authored: [Template.t()],
          files: [{Path.t(), String.t()}]
        }

  @doc """
  Plans an export of `templates` against `shipped` (this package's own
  defaults, as `default_system_templates/0` returns them).

  Options: `:out`, the target directory (default `#{@default_out}`).
  """
  @spec plan([Template.t()], [map()], keyword()) :: plan()
  def plan(templates, shipped, opts \\ []) do
    out = Keyword.get(opts, :out, @default_out)
    by_name = Map.new(shipped, &{&1.name, &1})

    {system, authored} = Enum.split_with(templates, & &1.is_system)
    {edited, untouched} = Enum.split_with(system, &edited?(&1, by_name))

    %{
      edited: edited,
      untouched: untouched,
      authored: authored,
      files: Enum.flat_map(edited, &files_for(&1, out))
    }
  end

  @doc """
  Whether `template` still matches what this package ships under its name.

  Compares the three content fields only — a slug, a usage count or a
  timestamp differing does not make a template customized.
  """
  @spec edited?(Template.t(), %{optional(String.t()) => map()}) :: boolean()
  def edited?(%Template{} = template, by_name) do
    case Map.get(by_name, template.name) do
      nil ->
        true

      default ->
        Enum.any?(@parts, fn {field, _stem, _ext} ->
          Map.get(template, field) != Map.get(default, field)
        end)
    end
  end

  @doc """
  The `{path, content}` pairs one template exports to.

  Empty and non-string values are skipped: a part a template does not supply
  is absent, not an empty file.
  """
  @spec files_for(Template.t(), Path.t()) :: [{Path.t(), String.t()}]
  def files_for(%Template{} = template, out \\ @default_out) do
    Enum.flat_map(@parts, fn {field, stem, extension} ->
      case Map.get(template, field) do
        map when is_map(map) -> part_files(map, template.name, stem, extension, out)
        _other -> []
      end
    end)
  end

  @doc """
  Writes planned `{path, content}` pairs, returning `{path, outcome}` for each.

  Outcomes are `:written`, `:would_write` (under `dry_run: true`) and
  `:skipped` — a path that already exists is **refused** unless `force: true`.
  That refusal is the point: a re-run, or an export onto a host that has
  already hand-written an override, must never silently replace a file a human
  wrote. Nothing here deletes.
  """
  @spec write_files([{Path.t(), String.t()}], keyword()) ::
          [{Path.t(), :written | :would_write | :skipped}]
  def write_files(files, opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)

    Enum.map(files, fn {path, content} ->
      cond do
        File.exists?(path) and not force? ->
          {path, :skipped}

        dry_run? ->
          {path, :would_write}

        true ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)
          {path, :written}
      end
    end)
  end

  defp part_files(field_map, name, stem, extension, out) do
    fallback = fallback_locale(field_map)

    for {locale, content} <- Enum.sort(field_map), is_binary(content), content != "" do
      suffix = if locale == fallback, do: "", else: ".#{locale}"
      {Path.join([out, name, "#{stem}#{suffix}.#{extension}"]), content}
    end
  end

  @doc """
  The locale every recipient falls through to: `"en"` when the map has it —
  the key `Template.get_translation/3` itself defaults to — otherwise the
  lowest-sorting one, so the choice is deterministic rather than whatever the
  map happens to yield first.
  """
  @spec fallback_locale(map()) :: String.t() | nil
  def fallback_locale(field_map) when is_map(field_map) do
    keys = field_map |> Map.keys() |> Enum.filter(&is_binary/1)

    cond do
      "en" in keys -> "en"
      keys == [] -> nil
      true -> Enum.min(keys)
    end
  end
end
