defmodule PhoenixKit.Modules.Emails.TemplateSources do
  @moduledoc """
  Which layer built a message, for the email log (#48).

  Core resolves an email as `host file override → default` (`PhoenixKit.Email.Content`),
  where the default is the copy core or an enabled module ships
  (`PhoenixKit.Email.Catalog`). The database layer that used to sit above them
  is retired. `origin/3` answers, from the template's name, which of the two a
  send used.

  Not every core API this reads is in every core: each is checked for before it
  is called, and on a core without one that half answers "nothing".
  """

  require Logger

  # Parts that make a directory an override of the message; `label` and
  # `layout` are captions and wrapper choices, not content.
  @content_parts [:subject, :text, :html, :markdown]

  @typedoc "`{source, template_uuid}` of `origin/3`."
  @type origin :: {String.t() | nil, String.t() | nil}

  @doc """
  The layer that built a message, for the log: `{source, template_uuid}`.

  `source` is `"file"` or `"module"`, and it is `nil` whenever there is no
  direct evidence of one, so the answer is looked up from the name:

    1. A host file override of the name exists for the message's `:locale`
       (a locale, its base language or the locale-less file; any content part):
       `{"file", nil}`. A file for another locale does not count.
    2. The name is in the catalog of defaults (core's, an enabled module's):
       `{"module", nil}`.
    3. Otherwise `{nil, nil}`: a message with its own content and a name that
       nothing resolves, such as a test send.

  Every lookup is a cached file probe (`Overrides.locate/4` caches absence too)
  or an in-memory list; nothing scans the override roots. (`"db"` is no longer
  produced: it survives only on log rows written before the layer was retired.)
  Never raises.

  Options: `:locale`, and for a host with files elsewhere and for tests
  `:roots`, `:overrides`, `:content` and `:catalog`.
  """
  @spec origin(term(), term(), keyword()) :: origin()
  def origin(name, uuid, opts \\ [])

  def origin(name, _uuid, _opts) when not is_binary(name) or name == "", do: {nil, nil}

  def origin(name, _uuid, opts) do
    origin_by_name(name, opts)
  rescue
    error -> failed("the source of #{inspect(name)}", error, {nil, nil})
  catch
    :exit, _ -> {nil, nil}
  end

  @doc "A well-formed uuid string, or `nil` (a log must not fail over a bad one)."
  @spec cast_uuid(term()) :: String.t() | nil
  def cast_uuid(uuid) when is_binary(uuid) and byte_size(uuid) == 36 do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  def cast_uuid(_uuid), do: nil

  defp origin_by_name(name, opts) do
    cond do
      file_override?(name, opts) -> {"file", nil}
      has_default?(name, opts) -> {"module", nil}
      true -> {nil, nil}
    end
  end

  defp file_override?(name, opts) do
    overrides = Keyword.get(opts, :overrides, PhoenixKit.Templates.Overrides)
    content = Keyword.get(opts, :content, PhoenixKit.Email.Content)

    if exported?(overrides, :locate, 4) and
         (Keyword.has_key?(opts, :roots) or exported?(content, :override_paths, 0)) do
      roots = Keyword.get_lazy(opts, :roots, fn -> content.override_paths() end)
      locale = Keyword.get(opts, :locale)

      Enum.any?(@content_parts, fn part ->
        case overrides.locate(roots, name, part, locale) do
          {_path, text} when is_binary(text) -> String.trim(text) != ""
          _ -> false
        end
      end)
    else
      false
    end
  end

  defp has_default?(name, opts) do
    catalog = Keyword.get(opts, :catalog, PhoenixKit.Email.Catalog)

    exported?(catalog, :entries, 0) and
      Enum.any?(catalog.entries(), &(&1.name == name and has_defaults?(&1)))
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
    Logger.warning(
      "Could not read #{what} for the log's template source: #{Exception.message(error)}"
    )

    fallback
  end
end
