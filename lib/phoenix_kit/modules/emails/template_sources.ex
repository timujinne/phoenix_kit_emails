defmodule PhoenixKit.Modules.Emails.TemplateSources do
  @moduledoc """
  Which layers a send could use for a template name, read-only (#48).

  Core resolves an email as `active database row → host file override → default`
  (`PhoenixKit.Email.Content.resolve_with_sources/5`), where the default is the
  copy core or an enabled module ships (`PhoenixKit.Email.Catalog`). An active
  row therefore hides the other two, and a file edited next to it "does
  nothing". `load/1` finds out, once, which names have a file override and
  which have a default; `layers/2` says which of them a given row hides.

  Not every core API this reads is in this package's `phoenix_kit` floor
  (2.21.3): `Content.override_paths/0` is, `Catalog.entries/0` arrived in
  2.44.0 and `Overrides.list/1` with `phoenix_kit_templates` 0.2.3 (cores 2.44
  to 2.61 accept `~> 0.2.2`). Each is checked for before it is called. On a core
  without one, that half answers "nothing", and no badge is shown — the page
  works as it did.
  """

  alias PhoenixKit.Modules.Emails.Template

  require Logger

  # Parts that make a directory an override of the message; `label` and
  # `layout` are captions and wrapper choices, not content.
  @content_parts [:subject, :text, :html, :markdown]

  @typedoc """
  `overrides` are the names with a file override, sorted; `defaults` maps a name with a
  default to the module that ships it (`nil` for core's own).
  """
  @type t :: %{overrides: [String.t()], defaults: %{String.t() => module() | nil}}

  @type layer :: :file | {:default, module() | nil}

  @doc "No overrides and no defaults: the answer on a core that cannot say."
  @spec empty() :: t()
  def empty, do: %{overrides: [], defaults: %{}}

  @doc """
  Reads the two layers below the database.

  Options (for a host that keeps its files elsewhere, and for tests):
  `:roots` (default: core's `override_paths/0`), and the modules to ask,
  `:overrides`, `:content` and `:catalog`.
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    %{overrides: load_overrides(opts), defaults: load_defaults(opts)}
  end

  @doc """
  The layers an active row hides, file override first.

  A row that is not active hides nothing: a send does not see it, so the file
  or the default below it is what is used.
  """
  @spec layers(Template.t() | nil, t()) :: [layer()]
  def layers(%Template{status: "active", name: name}, %{overrides: overrides, defaults: defaults}) do
    file = if name in overrides, do: [:file], else: []

    default =
      case Map.fetch(defaults, name) do
        {:ok, owner} -> [{:default, owner}]
        :error -> []
      end

    file ++ default
  end

  def layers(_template, _sources), do: []

  defp load_overrides(opts) do
    overrides = Keyword.get(opts, :overrides, PhoenixKit.Templates.Overrides)
    content = Keyword.get(opts, :content, PhoenixKit.Email.Content)

    if exported?(overrides, :list, 1) and
         (Keyword.has_key?(opts, :roots) or exported?(content, :override_paths, 0)) do
      roots = Keyword.get_lazy(opts, :roots, fn -> content.override_paths() end)

      roots
      |> Enum.flat_map(&overrides.list/1)
      |> Enum.filter(fn %{files: files} -> Enum.any?(files, &(&1.part in @content_parts)) end)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  rescue
    error -> failed("file overrides", error, [])
  end

  defp load_defaults(opts) do
    catalog = Keyword.get(opts, :catalog, PhoenixKit.Email.Catalog)

    if exported?(catalog, :entries, 0) do
      catalog.entries()
      |> Enum.filter(&has_defaults?/1)
      |> Map.new(&{&1.name, Map.get(&1, :module)})
    else
      %{}
    end
  rescue
    error -> failed("template defaults", error, %{})
  end

  # Catalog entries can advertise a file-only email without any defaults.
  # Do not evaluate callbacks here: they may depend on a recipient or locale.
  defp has_defaults?(%{defaults: defaults}) when is_function(defaults, 0), do: true

  defp has_defaults?(%{defaults: defaults}) when is_map(defaults) do
    Enum.any?(@content_parts, fn part ->
      case Map.get(defaults, part) do
        text when is_binary(text) -> String.trim(text) != ""
        _ -> false
      end
    end)
  end

  defp has_defaults?(_entry), do: false

  # `Code.ensure_loaded?/1` first: under interactive code loading a module that
  # is not loaded yet answers `false` to `function_exported?/3`.
  defp exported?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp failed(what, error, fallback) do
    Logger.warning("Could not read #{what} for the templates page: #{Exception.message(error)}")
    fallback
  end
end
