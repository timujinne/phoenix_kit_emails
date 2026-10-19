defmodule PhoenixKit.Modules.Emails.Verification.Dictionaries do
  @moduledoc """
  The word lists the pipeline checks against, loaded lazily into
  `:persistent_term` (one read-only copy per VM, no process in the way).

  ## Files

  `priv/email_verification/` ships five lists, one entry per line, `#` starts a
  comment, matching is case-insensitive:

    * `disposable.txt` - throw-away domains; a listed domain covers its subdomains
    * `free.txt` - free mailbox providers; `name.*` matches `name.<tld>` and
      `name.<co|com|org|...>.<tld>`
    * `tlds.txt` - valid top-level domains
    * `role_prefixes.txt` - shared-mailbox local parts (`info`, `sales`, ...)
    * `not_fake.txt` - whitelist: domains never treated as disposable

  Where each came from is in `priv/email_verification/SOURCES.md`.

  ## External directory

  If `Config.lists_dir/0` names a directory, any file there with one of the
  names above is **merged on top** of the shipped one (union, never replace).
  That is how a host adds lists it may not redistribute. A file that is missing
  or unreadable is skipped. The lists are read once per VM: call `reload/0`
  after changing the directory or its files.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config

  @names [:disposable, :free, :tlds, :role_prefixes, :not_fake]

  @doc "`true` when `tld` (without the dot) is in the IANA list."
  @spec valid_tld?(String.t()) :: boolean()
  def valid_tld?(tld), do: MapSet.member?(set(:tlds), String.downcase(tld))

  @doc "`true` when `domain`, or a parent of it, is a listed disposable domain and is not whitelisted."
  @spec disposable?(String.t()) :: boolean()
  def disposable?(domain) do
    domain = String.downcase(domain)
    listed_with_parents?(set(:disposable), domain) and not not_fake?(domain)
  end

  @doc "`true` when `domain`, or a parent of it, is whitelisted in `not_fake.txt`."
  @spec not_fake?(String.t()) :: boolean()
  def not_fake?(domain), do: listed_with_parents?(set(:not_fake), String.downcase(domain))

  @doc "`true` when `domain` is a free mailbox provider."
  @spec free?(String.t()) :: boolean()
  def free?(domain) do
    domain = String.downcase(domain)
    {exact, wildcards} = free_patterns()

    MapSet.member?(exact, domain) or Enum.any?(wildcards, &wildcard_match?(&1, domain))
  end

  @doc "`true` when `local` (ignoring a `+tag` suffix) is a role-account prefix."
  @spec role?(String.t()) :: boolean()
  def role?(local) do
    base = local |> String.downcase() |> String.split("+", parts: 2) |> hd()
    MapSet.member?(set(:role_prefixes), base)
  end

  @doc "Forgets every loaded list; the next lookup reads the files again."
  @spec reload() :: :ok
  def reload do
    Enum.each(@names ++ [:free_patterns], &:persistent_term.erase({__MODULE__, &1}))
  end

  @doc "Number of entries in the list `name` (shipped + external)."
  @spec size(atom()) :: non_neg_integer()
  def size(name) when name in @names, do: name |> set() |> MapSet.size()

  defp set(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil -> load_and_store(key, name)
      set -> set
    end
  end

  defp load_and_store(key, name) do
    set = load(name)
    :persistent_term.put(key, set)
    set
  end

  defp free_patterns do
    key = {__MODULE__, :free_patterns}

    case :persistent_term.get(key, nil) do
      nil ->
        patterns =
          set(:free)
          |> Enum.split_with(&(not String.ends_with?(&1, ".*")))
          |> then(fn {exact, wild} ->
            {MapSet.new(exact), Enum.map(wild, &String.trim_trailing(&1, "*"))}
          end)

        :persistent_term.put(key, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  # "yahoo." matches yahoo.com and yahoo.co.uk, but neither yahoo.evil.com nor
  # yahoo.a.b.com: what follows the prefix is a TLD, optionally behind a
  # generic second-level label (co, com, org, ...).
  @second_levels ~w(co com org net ac or ne gov edu)

  defp wildcard_match?(prefix, domain) do
    if String.starts_with?(domain, prefix) do
      domain
      |> binary_part(byte_size(prefix), byte_size(domain) - byte_size(prefix))
      |> String.split(".")
      |> suffix_ok?()
    else
      false
    end
  end

  defp suffix_ok?([tld]), do: valid_tld?(tld)
  defp suffix_ok?([second, tld]), do: second in @second_levels and valid_tld?(tld)
  defp suffix_ok?(_labels), do: false

  defp listed_with_parents?(set, domain) do
    domain
    |> parent_domains()
    |> Enum.any?(&MapSet.member?(set, &1))
  end

  # "a.b.c.com" -> ["a.b.c.com", "b.c.com", "c.com"]: the domain and each parent,
  # never the bare TLD.
  defp parent_domains(domain) do
    labels = String.split(domain, ".")
    for n <- 0..(length(labels) - 2)//1, do: labels |> Enum.drop(n) |> Enum.join(".")
  end

  defp load(name) do
    file = Atom.to_string(name) <> ".txt"

    [shipped_path(file), external_path(file)]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&read_lines/1)
    |> MapSet.new()
  end

  defp shipped_path(file) do
    Path.join([Application.app_dir(:phoenix_kit_emails), "priv", "email_verification", file])
  end

  defp external_path(file) do
    case Config.lists_dir() do
      nil -> nil
      dir -> Path.join(dir, file)
    end
  end

  defp read_lines(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> []
    end
  end

  defp parse(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
