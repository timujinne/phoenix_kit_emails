defmodule PhoenixKit.Modules.Emails.Verification.Flags do
  @moduledoc """
  The fake, curse and typo flags of an address.

  They are **flags, not verdicts**: notes on the original tool
  say "Fake Pattern and Curse Words are not a verdict", because the heuristic
  also catches legitimate addresses (initials such as `aha@hjj.dk`). They are
  stored on the result and never change its status.

  `local` is the part before the `@` with any `+tag` already removed, `domain`
  the normalised domain. Matching is case-insensitive.

  ## fake

  True unless the domain (or a parent) is whitelisted in `not_fake.txt`, and
  then true when any of these holds:

    * the address is in the fake list (`fake.txt` / `FakeAddresses_Sorted.txt`):
      an entry is `@domain`, `local@` (the whole local part), `local@domain`
      or a bare local part;
    * the local part looks throw-away (below);
    * the second-level label of the domain looks throw-away - unless the domain
      is a known free provider, whose name is not ours to judge.

  A name looks throw-away when it is digits only, one letter repeated, has the
  same letter three times in a row, contains a keyboard run (`asdf`, `qwer`,
  `ghjkl`, ...), or has no vowel (`aeiouy`) and is long enough: seven or more
  characters (dots removed) or eight or more (dots counted), or has nine or more
  characters in a row without a vowel (dots removed). The local part is also fake
  with four or more dots (`a.b.c.d.e`, the "initials with dots" pattern
  `^([a-z]+\.){4,}`, which the dot count includes); a `dr`, `jr` or `sr` segment
  is not counted.

  The thresholds follow the original tool. A short name without vowels is
  deliberately *not* fake: `hjj`, `skf` or `bbc` are legitimate initials, exactly
  the false positives of the older "three or more characters" rule. Where the
  original was loose (whether the eight-character rule counts the dots) this is our
  reading.

  ## curse

  A word of the curse list (`curse.txt` / `CurseWords_Sorted.txt`) is a whole
  word of the address: the address is cut into words at everything that is not
  a letter, so `john.blorp@` and `blorp123@` match `blorp` but `blorpy@` does
  not. A list entry of two or three words matches consecutive words.

  ## typo

  The address is in the typo list (`typos.txt` / `Typos_Sorted.txt`), usually a
  misspelt provider written as `@gmai.com`. Same entry forms as the fake list.
  """

  alias PhoenixKit.Modules.Emails.Verification.Dictionaries

  @type t :: %{fake: boolean(), curse: boolean(), typo: boolean()}

  @max_curse_words 3
  @keyboard_runs ~w(asdf sdfg dfgh fghj ghjk hjkl qwer zxcv xcvb)
  @titles ~w(dr jr sr)

  @doc "All three flags."
  @spec compute(String.t(), String.t()) :: t()
  def compute(local, domain) do
    %{fake: fake?(local, domain), curse: curse?(local, domain), typo: typo?(local, domain)}
  end

  @doc "The fake-address flag."
  @spec fake?(String.t(), String.t()) :: boolean()
  def fake?(local, domain) do
    local = String.downcase(local)
    domain = String.downcase(domain)

    not Dictionaries.not_fake?(domain) and
      (address_listed?(:fake, local, domain) or throwaway_local?(local) or
         throwaway_domain?(domain))
  end

  @doc "The curse-word flag."
  @spec curse?(String.t(), String.t()) :: boolean()
  def curse?(local, domain) do
    words = (local <> "@" <> domain) |> String.downcase() |> String.split(~r/[^a-z]+/, trim: true)

    Enum.any?(1..@max_curse_words, fn size ->
      words
      |> Enum.chunk_every(size, 1, :discard)
      |> Enum.any?(&Dictionaries.listed?(:curse, Enum.join(&1, " ")))
    end)
  end

  @doc "The typo flag."
  @spec typo?(String.t(), String.t()) :: boolean()
  def typo?(local, domain) do
    address_listed?(:typos, String.downcase(local), String.downcase(domain))
  end

  defp address_listed?(list, local, domain) do
    Enum.any?(
      ["@" <> domain, local <> "@", local <> "@" <> domain, local],
      &Dictionaries.listed?(list, &1)
    )
  end

  ## --- The heuristic ---

  defp throwaway_local?(local) do
    segments = local |> String.split(".") |> Enum.reject(&(&1 in @titles))

    throwaway_name?(Enum.join(segments)) or vowelless?(Enum.join(segments, "."), 8) or
      length(segments) > 4
  end

  # An internationalised label (punycode) has no vowels to count.
  defp throwaway_domain?(domain) do
    label = second_level(domain)

    not String.starts_with?(label, "xn--") and not Dictionaries.free?(domain) and
      throwaway_name?(label)
  end

  # `name.co.uk` -> "name"; `name.com` -> "name"; `sub.name.org` -> "name".
  defp second_level(domain) do
    case domain |> String.split(".") |> Enum.reverse() do
      [_tld, generic, name | _] ->
        if Dictionaries.generic_second_level?(generic), do: name, else: generic

      [_tld, name] ->
        name

      [name] ->
        name
    end
  end

  defp throwaway_name?(""), do: false

  defp throwaway_name?(name) do
    Regex.match?(~r/\A\d+\z/, name) or
      Regex.match?(~r/\A(.)\1+\z/, name) or
      Regex.match?(~r/([a-z])\1\1/, name) or
      Enum.any?(@keyboard_runs, &String.contains?(name, &1)) or
      vowelless?(name, 7) or
      Regex.match?(~r/[^aeiouy]{9,}/, name)
  end

  defp vowelless?(name, min_length),
    do: String.length(name) >= min_length and not Regex.match?(~r/[aeiouy]/, name)
end
