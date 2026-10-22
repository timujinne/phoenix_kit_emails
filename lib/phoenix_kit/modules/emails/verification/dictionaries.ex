defmodule PhoenixKit.Modules.Emails.Verification.Dictionaries do
  @moduledoc """
  The word lists the pipeline checks against, loaded lazily into
  `:persistent_term` (one read-only copy per VM, no process in the way).

  ## Files

  `priv/email_verification/` ships one file per list, one entry per line, `#`
  starts a comment, matching is case-insensitive. Line endings may be LF or CRLF.

    * `disposable.txt` - throw-away domains; a listed domain covers its subdomains
    * `free.txt` - free mailbox providers; `name.*` matches `name.<tld>` and
      `name.<co|com|org|...>.<tld>`
    * `tlds.txt` - valid top-level domains (a leading dot is ignored)
    * `role_prefixes.txt` - shared-mailbox local parts (`info`, `sales`, ...)
    * `not_fake.txt` - whitelist: domains never treated as disposable or fake
    * `typos.txt`, `fake.txt` - address patterns for the typo and fake flags, see
      `Verification.Flags` (shipped empty)
    * `curse.txt` - words for the curse flag (shipped empty)
    * `smtp_greylist.txt`, `smtp_quota.txt`, `smtp_block.txt` - phrases for
      classifying an SMTP reply (`Verification.Classifier`); exposed by `phrases/1`
      (shipped empty: the Kellerman lists are not redistributable)
    * `smtp_user_unknown.txt` - generic "no such mailbox" phrases that keep a refusal
      from being read as a block (`user unknown`, `5.1.1`, ...); exposed by `phrases/1`
      (shipped with ten entries)

  Where each came from is in `priv/email_verification/SOURCES.md`.

  ## External directory

  If `Config.lists_dir/0` names a directory, any file there with one of the
  names above is **merged on top** of the shipped one (union, never replace).
  That is how a host adds lists it may not redistribute.

  The directory may also hold the LetsExtract/Kellerman files under their own
  names, as they are (CRLF, TLDs with a leading dot): `DEA_Sorted.txt`
  (disposable), `FreeEmail_Sorted.txt` (free), `TopLevelDomains.txt` (tlds),
  `Typos_Sorted.txt`, `FakeAddresses_Sorted.txt`, `CurseWords_Sorted.txt`,
  `Greylisting_Sorted.txt`, `MailboxQuota_Sorted.txt` and `Blocking_Sorted.txt`
  (the three SMTP phrase lists). Our own name and the Kellerman one can both be
  present; they are unioned.

  A file missing from the directory is skipped; a directory that does not exist,
  or a file that exists but cannot be read, is skipped with a logged warning. The
  lists are read once per VM: call `reload/0` after changing the directory or its
  files. If the settings store cannot be read at the first lookup the shipped
  lists are used for 30 seconds and the directory is looked up again after that.
  """

  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Config

  # kind => file names. The first is ours (shipped in priv, and looked up in the
  # external directory); the rest are the Kellerman names, external only.
  @sources %{
    disposable: ["disposable.txt", "DEA_Sorted.txt"],
    free: ["free.txt", "FreeEmail_Sorted.txt"],
    tlds: ["tlds.txt", "TopLevelDomains.txt"],
    role_prefixes: ["role_prefixes.txt"],
    not_fake: ["not_fake.txt"],
    typos: ["typos.txt", "Typos_Sorted.txt"],
    fake: ["fake.txt", "FakeAddresses_Sorted.txt"],
    curse: ["curse.txt", "CurseWords_Sorted.txt"],
    smtp_grey: ["smtp_greylist.txt", "Greylisting_Sorted.txt"],
    smtp_quota: ["smtp_quota.txt", "MailboxQuota_Sorted.txt"],
    smtp_block: ["smtp_block.txt", "Blocking_Sorted.txt"],
    smtp_user_unknown: ["smtp_user_unknown.txt"]
  }
  @names Map.keys(@sources)
  # Lists of domains: an entry may be written with a leading dot (".aaa").
  @domain_lists [:disposable, :free, :tlds, :not_fake]
  @phrase_lists [:smtp_grey, :smtp_quota, :smtp_block, :smtp_user_unknown]
  @second_levels ~w(co com org net ac or ne gov edu)
  @key {__MODULE__, :snapshot}
  @retry_ms 30_000

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

  @doc """
  `true` when `entry` is a line of the list `name` (case-insensitive, otherwise
  exact). The flags use it for address patterns such as `@domain.com`.
  """
  @spec listed?(atom(), String.t()) :: boolean()
  def listed?(name, entry) when name in @names,
    do: MapSet.member?(set(name), String.downcase(entry))

  @doc """
  The phrases of an SMTP reply list (`:smtp_grey`, `:smtp_quota`, `:smtp_block`,
  `:smtp_user_unknown`), sorted, lowercase. `Verification.Classifier` reads them.
  """
  @spec phrases(:smtp_grey | :smtp_quota | :smtp_block | :smtp_user_unknown) :: [String.t()]
  def phrases(name) when name in @phrase_lists, do: name |> set() |> Enum.sort()

  @doc false
  # `co`, `com`, `org`, ... - the generic label that may sit between a name and a
  # country TLD (`name.co.uk`).
  @spec generic_second_level?(String.t()) :: boolean()
  def generic_second_level?(label), do: label in @second_levels

  @doc "Forgets every loaded list; the next lookup reads the files again."
  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@key)
    :ok
  end

  @doc "Number of entries in the list `name` (shipped + external)."
  @spec size(atom()) :: non_neg_integer()
  def size(name) when name in @names, do: name |> set() |> MapSet.size()

  defp set(name), do: Map.fetch!(snapshot(), name)

  defp free_patterns, do: Map.fetch!(snapshot(), :free_patterns)

  # All five lists and the split free patterns, built together so that a lookup
  # never mixes two generations of files.
  defp snapshot do
    case :persistent_term.get(@key, nil) do
      %{} = snapshot -> snapshot
      {:partial, snapshot, retry_at} -> partial_or_reload(snapshot, retry_at)
      nil -> load_snapshot()
    end
  end

  defp partial_or_reload(snapshot, retry_at) do
    if System.monotonic_time(:millisecond) < retry_at, do: snapshot, else: load_snapshot()
  end

  # When the settings store cannot be read, the external directory is unknown.
  # The shipped lists are used meanwhile, but only for a short while: caching
  # that forever would silently drop the host's private lists.
  defp load_snapshot do
    {dir, trusted?} =
      case Config.lists_dir_lookup() do
        {:ok, dir} -> {dir, true}
        :error -> {nil, false}
      end

    warn_unless_directory(dir)
    lists = Map.new(@names, &{&1, load(&1, dir)})
    snapshot = Map.put(lists, :free_patterns, split_free(lists.free))

    if trusted? do
      :persistent_term.put(@key, snapshot)
    else
      Logger.warning(
        "Email verification: settings unreadable, using the shipped word lists only " <>
          "(retry in #{@retry_ms} ms)"
      )

      retry_at = System.monotonic_time(:millisecond) + @retry_ms
      :persistent_term.put(@key, {:partial, snapshot, retry_at})
    end

    snapshot
  end

  defp split_free(free) do
    {exact, wild} = Enum.split_with(free, &(not String.ends_with?(&1, ".*")))
    {MapSet.new(exact), Enum.map(wild, &String.trim_trailing(&1, "*"))}
  end

  defp warn_unless_directory(nil), do: :ok

  defp warn_unless_directory(dir) do
    unless File.dir?(dir) do
      Logger.warning(
        "Email verification: lists directory #{inspect(dir)} does not exist or is not a " <>
          "directory; its lists are NOT applied"
      )
    end

    :ok
  end

  # "yahoo." matches yahoo.com and yahoo.co.uk, but neither yahoo.evil.com nor
  # yahoo.a.b.com: what follows the prefix is a TLD, optionally behind a
  # generic second-level label (co, com, org, ...).
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

  defp load(name, dir) do
    [own | others] = Map.fetch!(@sources, name)

    [shipped_path(own) | if(dir, do: Enum.map([own | others], &Path.join(dir, &1)), else: [])]
    |> Enum.flat_map(&read_lines(&1, name))
    |> MapSet.new()
  end

  defp shipped_path(file) do
    Path.join([Application.app_dir(:phoenix_kit_emails), "priv", "email_verification", file])
  end

  # A file absent from an existing directory is normal (a host may supply only
  # some lists); any other failure to read is not, and is said out loud.
  defp read_lines(path, name) do
    case File.read(path) do
      {:ok, content} ->
        parse(content, name)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning(
          "Email verification: cannot read #{inspect(path)} (#{:file.format_error(reason)}); " <>
            "skipped"
        )

        []
    end
  end

  # LF or CRLF; a byte-order mark and the dot of ".aaa" are dropped.
  defp parse(content, name) do
    content
    |> String.trim_leading("\uFEFF")
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> entry(name)))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp entry(line, name) when name in @domain_lists, do: String.trim_leading(line, ".")
  defp entry(line, _name), do: line
end
