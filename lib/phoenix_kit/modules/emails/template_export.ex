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

  ## Raw-HTML variables in the `html` part

  `phoenix_kit_templates` from 0.2.0 onward escapes `{{var}}` values in an
  `html` part, and offers `{{{var}}}` (triple braces) as the opt-out for a
  variable, such as billing's `line_items_html`, whose value is already
  rendered HTML. `plan/3` rewrites the names `Template.raw_html_variables/0`
  lists into that triple-brace form when the host's loaded
  `phoenix_kit_templates` is new enough to understand it, and reports each
  file it touched via `plan.notices`. Below 0.2.0, that syntax has no special
  meaning at all — see `rewrite_raw_html/3` — so the file is written
  unchanged, with a notice saying it needs a manual edit once core (and
  `phoenix_kit_templates` with it) is upgraded. `subject` and `text` are never
  rewritten: they are always plain text there, and at `phoenix_kit_templates`
  >= 0.2.0 double and triple braces behave identically outside an escaped
  `html` part; below 0.2.0 a triple brace there would be read as literal
  braces around a substituted double pair, which is exactly why `plan/3`
  never touches those two parts in the first place.
  """

  alias PhoenixKit.Modules.Emails.Template

  @default_out "priv/phoenix_kit_templates"
  @raw_html_min_version "0.2.0"

  # Stored field -> {file stem, extension}. Only `html` is markup.
  @parts [{:subject, "subject", "txt"}, {:text_body, "text", "txt"}, {:html_body, "html", "html"}]

  # The character classes and whitespace handling below are copied from
  # `PhoenixKit.Templates.Substitution`'s own placeholder pattern by design.
  # This module cannot reuse `Substitution.variables/1` directly: that
  # function recognizes both the double- and triple-brace form of a name,
  # but has no way to report which of the two matched a given occurrence —
  # exactly the distinction "already raw, leave alone" vs "double brace,
  # rewrite" needs. Below `phoenix_kit_templates` 0.2.0, the triple-brace
  # form has no special meaning — it renders as literal braces around a
  # substituted double pair.
  @placeholder ~r/
    \{\{\{\s*(?<triple>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}\}
    |
    \{\{\s*(?<double>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}
  /x

  @typedoc """
  What an export would do, without having done any of it. `raw_html_supported`
  is the flag `plan/3` actually used to build `notices` — a caller that later
  needs to re-derive a notice against a file `write_files/2` skipped (see
  `reconcile_skipped_notice/2`) reads it from here rather than recomputing it,
  so the recheck is done with the exact same answer this plan was built with.
  """
  @type plan :: %{
          edited: [Template.t()],
          untouched: [Template.t()],
          authored: [Template.t()],
          files: [{Path.t(), String.t()}],
          notices: [notice()],
          raw_html_supported: boolean()
        }

  @typedoc """
  One file's worth of raw-HTML-variable news, still missing the file's actual
  write outcome — `notice_message/2` fills that in once `write_files/2` has
  run. `:rewritten` is the only kind whose wording depends on that outcome;
  `:needs_manual_rewrite` and `:unknown_placeholder` describe the template's
  content, which this run either could not or should not touch regardless of
  whether the file itself ended up written, skipped, or only planned.
  `:could_not_verify` is what `reconcile_skipped_notice/2` produces when it
  could not even read the file back to check it.

  `raw_html_supported` is carried on every notice — not only implied by
  `kind` — because `:unknown_placeholder`'s wording needs it too: the advice
  for an unrecognized `{{..._html}}` placeholder is the opposite depending on
  whether `phoenix_kit_templates` understands triple braces yet.
  """
  @type notice :: %{
          path: Path.t(),
          kind: :rewritten | :needs_manual_rewrite | :unknown_placeholder | :could_not_verify,
          names: [String.t()],
          raw_html_supported: boolean()
        }

  @doc """
  Plans an export of `templates` against `shipped` (this package's own
  defaults, as `default_system_templates/0` returns them).

  Options:

    * `:out` — the target directory (default `#{@default_out}`).
    * `:raw_html_supported` — whether the `html` part may use `{{{var}}}` for
      a raw-HTML variable (see `rewrite_raw_html/3`). Defaults to detecting
      the loaded `phoenix_kit_templates` version; pass it explicitly to pin
      the behaviour regardless of what happens to be on the load path. Any
      value is accepted and coerced to a strict boolean the same way `if`
      would treat it (only `false` and `nil` are falsy), rather than raising
      on a caller's `nil` or truthy-but-not-`true` value.
  """
  @spec plan([Template.t()], [map()], keyword()) :: plan()
  def plan(templates, shipped, opts \\ []) do
    out = Keyword.get(opts, :out, @default_out)

    raw_html_supported? =
      !!Keyword.get_lazy(opts, :raw_html_supported, &default_raw_html_support?/0)

    by_name = Map.new(shipped, &{&1.name, &1})

    {system, authored} = Enum.split_with(templates, & &1.is_system)
    {edited, untouched} = Enum.split_with(system, &edited?(&1, by_name))

    {files, notices} =
      edited
      |> Enum.flat_map(&files_for(&1, out))
      |> Enum.map_reduce([], &rewrite_html_file(&1, &2, raw_html_supported?))

    %{
      edited: edited,
      untouched: untouched,
      authored: authored,
      files: files,
      notices: notices,
      raw_html_supported: raw_html_supported?
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
  is absent, not an empty file. This function does not apply the raw-HTML
  rewrite documented on `rewrite_raw_html/3` — `plan/3` does that afterward,
  for whichever of these pairs its path ends in `.html`.
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

  @doc """
  Rewrites `Template.raw_html_variables/0` names in an `html` part from
  `{{var}}` to `{{{var}}}`, when `raw_html_supported?` is true — the escaping
  opt-out `phoenix_kit_templates` understands from 0.2.0 onward. Below that
  version the triple-brace form has no special meaning at all — a copy of it
  renders as literal braces around a substituted double pair (see
  `PhoenixKit.Templates.Substitution`'s moduledoc) — so nothing is rewritten.
  Either way, `notice_message/2` is what turns the returned notices into
  operator-facing text; this function only classifies what it found.

  An already-triple-braced placeholder is left alone — this is what keeps the
  rewrite idempotent across repeated exports, and across a single part that
  mixes both forms of the same name. A `{{..._html}}` placeholder that is
  *not* on `raw_html_variables/0` is also left alone, but reported: a new
  pre-rendered-HTML variable must be added to that list before an export can
  safely convert it, so silently leaving it as `{{var}}` (still correct under
  `phoenix_kit_templates` < 0.2.0, still wrong under `escape: true` at
  0.2.0+) needs a human to notice.

  A double-brace placeholder is a rewrite candidate either because its name
  is on `raw_html_variables/0` (regardless of how it happens to be spelled —
  a known name is known by being on that list, not by its casing or suffix),
  or, failing that, because its name merely *looks* like it might belong
  there (ends in `_html`, matched case-insensitively), which is what makes an
  unrecognized one worth a notice instead of silent passage.

  Returns at most one notice per `path` for the rewritten/pending-rewrite
  names, and one more for any unrecognized ones — never one notice per
  variable, so a template with several raw-HTML variables does not flood the
  export report with a line each.

  `opts[:known]` overrides `Template.raw_html_variables/0` — test-only, so a
  name's behavior can be exercised without actually adding it to that list.
  """
  @spec rewrite_raw_html(String.t(), Path.t(), boolean(), keyword()) :: {String.t(), [notice()]}
  def rewrite_raw_html(content, path, raw_html_supported?, opts \\ []) when is_binary(content) do
    known = Keyword.get(opts, :known, Template.raw_html_variables())

    double_names =
      @placeholder
      |> Regex.scan(content, capture: :all_names)
      |> Enum.flat_map(fn
        [double, ""] when double != "" -> [double]
        [_double, _triple] -> []
      end)
      |> Enum.uniq()

    {known_names, candidate_unknown_names} = Enum.split_with(double_names, &(&1 in known))

    unknown_names =
      Enum.filter(candidate_unknown_names, &String.ends_with?(String.downcase(&1), "_html"))

    new_content =
      if raw_html_supported? and known_names != [] do
        Regex.replace(@placeholder, content, fn full, triple, double ->
          cond do
            triple != "" -> full
            double in known_names -> "{{{#{double}}}}"
            true -> full
          end
        end)
      else
        content
      end

    {new_content, build_notices(path, known_names, unknown_names, raw_html_supported?)}
  end

  defp build_notices(path, known_names, unknown_names, raw_html_supported?) do
    known_kind = if raw_html_supported?, do: :rewritten, else: :needs_manual_rewrite

    [
      if(known_names != [],
        do: %{
          path: path,
          kind: known_kind,
          names: known_names,
          raw_html_supported: raw_html_supported?
        }
      ),
      if(unknown_names != [],
        do: %{
          path: path,
          kind: :unknown_placeholder,
          names: unknown_names,
          raw_html_supported: raw_html_supported?
        }
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Renders one `notice/0` into `{level, message}`, where `level` is `:info` or
  `:warning` — the mix task uses `level` to decide how loudly to print it.

  `outcome` is the file's own outcome from `write_files/2` (`:written`,
  `:would_write`, `:skipped`, or `nil` when the notice has not gone through a
  real write at all, e.g. when `rewrite_raw_html/3` is called directly — that
  reads as "not written yet", so it takes the same wording as `:would_write`
  rather than claiming a rewrite already happened). `outcome` only changes
  the wording for `:rewritten`: that kind describes a content change this run
  either made or is only proposing, and a skipped file (an existing override
  `write_files/2` refused to touch) was not actually rewritten, no matter
  what the content passed to `rewrite_raw_html/3` looked like — saying
  otherwise would read to an operator as a rewrite that did not in fact
  happen. The other kinds describe the template's own content, independent of
  whether this run wrote, skipped, or only planned the file, so `outcome`
  does not affect them. `:unknown_placeholder`'s wording still depends on
  `raw_html_supported` (carried on the notice itself): the advice for an
  unrecognized `{{..._html}}` name is the exact opposite on either side of
  that line — "change it to `{{{var}}}` now" is correct advice once
  `phoenix_kit_templates` understands triple braces, and actively wrong
  before that (it would read as a literal, escaped brace).
  `:could_not_verify` — `reconcile_skipped_notice/2` could not even read the
  file back — is always a warning too, regardless of `outcome`.

  For a `:skipped` file specifically, call `reconcile_skipped_notice/2` first
  — this function trusts the notice it is given and has no way on its own to
  tell a file that is still wrong from one a previous run, or an operator's
  own edit, already fixed.
  """
  @spec notice_message(notice(), :written | :would_write | :skipped | nil) ::
          {:info | :warning, String.t()}
  def notice_message(%{path: path, kind: :rewritten, names: names}, outcome) do
    double = as_double(names)
    triple = as_triple(names)

    case outcome do
      :skipped ->
        {:warning,
         "#{path}: skipped (existing file, not overwritten) — #{double} is still written " <>
           "as-is in it; edit the file by hand to #{triple}"}

      :written ->
        {:info, "#{path}: rewrote #{double} to #{triple} (already-rendered HTML)"}

      _would_write_or_unknown ->
        {:info, "#{path}: would rewrite #{double} to #{triple} (already-rendered HTML)"}
    end
  end

  def notice_message(%{path: path, kind: :needs_manual_rewrite, names: names}, _outcome) do
    double = as_double(names)
    triple = as_triple(names)

    {:warning,
     "#{path}: #{double} holds already-rendered HTML but the loaded phoenix_kit_templates " <>
       "does not support {{{...}}} yet — after upgrading core to >= 2.40 " <>
       "(phoenix_kit_templates ~> 0.2.0), replace #{double} with #{triple} in this file"}
  end

  def notice_message(
        %{path: path, kind: :unknown_placeholder, names: names, raw_html_supported: true},
        _outcome
      ) do
    {:warning,
     "#{path}: unknown raw-HTML placeholder #{as_double(names)} — left as-is. If its value " <>
       "is already-rendered HTML, change it to #{as_triple(names)} by hand in this file, and " <>
       "let the phoenix_kit_emails maintainer know so raw_html_variables/0 can be updated"}
  end

  def notice_message(
        %{path: path, kind: :unknown_placeholder, names: names, raw_html_supported: false},
        _outcome
      ) do
    {:warning,
     "#{path}: unknown raw-HTML placeholder #{as_double(names)} — left as-is. Do NOT change " <>
       "it to #{as_triple(names)} now — the loaded phoenix_kit_templates does not support " <>
       "{{{...}}} yet, and it has no special meaning there. If its value is already-rendered " <>
       "HTML, it will need that form once core is upgraded to >= 2.40 " <>
       "(phoenix_kit_templates ~> 0.2.0). Let the phoenix_kit_emails maintainer know so " <>
       "raw_html_variables/0 can be updated"}
  end

  def notice_message(%{path: path, kind: :could_not_verify}, _outcome) do
    {:warning, "could not read #{path} to check whether it still needs a raw-HTML fix"}
  end

  @doc """
  Re-derives `notice` against what is actually on disk at its `path`, for a
  file `write_files/2` skipped because it already existed — the notice
  `rewrite_raw_html/3` built described the content this run *would have*
  written, not the file this run left alone.

  Returns `nil` when the file on disk no longer has the problem `notice`
  described — a previous run already fixed it, or an operator did by hand —
  so a re-run without `--force` stops repeating a warning that no longer
  applies. `raw_html_supported?` should be the same flag the plan that
  produced `notice` used (`plan.raw_html_supported`), so the recheck answers
  the same question the original notice did. Only ever call this for a
  `:skipped` outcome; for any other outcome the plan-time notice already
  describes exactly what this run did.

  A file can have both a still-unresolved known variable and an unrecognized
  placeholder at once — re-deriving `notice`'s *own* kind (rather than, say,
  the first fresh notice found) is what keeps a two-problem file from getting
  the same message twice instead of one message per problem.

  When the file cannot even be read (permissions, `path` is a directory, it
  vanished after `write_files/2` ran), this has no evidence either way, so it
  returns a `:could_not_verify` notice rather than silently reusing the
  plan-time one — that would claim the file's content is something this
  function never actually confirmed.
  """
  @spec reconcile_skipped_notice(notice(), boolean()) :: notice() | nil
  def reconcile_skipped_notice(%{path: path, kind: kind} = notice, raw_html_supported?) do
    case File.read(path) do
      {:ok, on_disk} ->
        {_content, fresh_notices} = rewrite_raw_html(on_disk, path, raw_html_supported?)
        Enum.find(fresh_notices, &(&1.kind == kind))

      {:error, _reason} ->
        %{notice | kind: :could_not_verify}
    end
  end

  defp as_double(names), do: Enum.map_join(names, ", ", &"{{#{&1}}}")
  defp as_triple(names), do: Enum.map_join(names, ", ", &"{{{#{&1}}}}")

  defp rewrite_html_file({path, content}, notices, raw_html_supported?) do
    if String.ends_with?(path, ".html") do
      {new_content, file_notices} = rewrite_raw_html(content, path, raw_html_supported?)
      {{path, new_content}, notices ++ file_notices}
    else
      {{path, content}, notices}
    end
  end

  @doc false
  @spec default_raw_html_support? :: boolean()
  def default_raw_html_support? do
    case Application.spec(:phoenix_kit_templates, :vsn) do
      nil ->
        _ = Application.load(:phoenix_kit_templates)
        raw_html_support?(Application.spec(:phoenix_kit_templates, :vsn))

      vsn ->
        raw_html_support?(vsn)
    end
  end

  @doc false
  @spec raw_html_support?(charlist() | String.t() | nil) :: boolean()
  def raw_html_support?(nil), do: false

  def raw_html_support?(vsn) do
    vsn |> to_string() |> Version.match?(">= #{@raw_html_min_version}")
  rescue
    Version.InvalidVersionError -> false
  end
end
