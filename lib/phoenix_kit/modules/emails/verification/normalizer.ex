defmodule PhoenixKit.Modules.Emails.Verification.Normalizer do
  @moduledoc """
  Step 1 of the pipeline: turn user input into `local@domain` parts.

  Trims surrounding whitespace, splits at the single `@`, lowercases the domain
  and converts an internationalised domain to punycode (`:idna`, already
  present through `hackney`). The local part is kept exactly as typed - it is
  case-sensitive in principle and the engine has no business rewriting it.

  Normalising does not validate: `Syntax.check/2` does that on the result.
  """

  @type parts :: %{email: String.t(), local: String.t(), domain: String.t()}
  @type error :: :not_a_string | :empty | :bad_at | :bad_idn

  @spec normalize(term()) :: {:ok, parts()} | {:error, error()}
  def normalize(input) when is_binary(input) do
    case input |> String.trim() |> split() do
      {:ok, local, domain} -> build(local, domain)
      {:error, _} = error -> error
    end
  end

  def normalize(_input), do: {:error, :not_a_string}

  @doc """
  The key a result is stored and looked up under: the normalised address when
  there is one, otherwise the trimmed input (a malformed address still gets a
  stored verdict), cut at 320 characters. `nil` for input that is not text, is
  blank, or cannot be stored at all - invalid UTF-8 and NUL bytes, which
  PostgreSQL rejects in a text column.
  """
  @spec storage_key(term()) :: String.t() | nil
  def storage_key(input) when is_binary(input) do
    if storable?(input), do: storage_key(input, normalize(input))
  end

  def storage_key(_input), do: nil

  @doc """
  `storage_key/1` for a caller that already ran `normalize/1` on `input`, so
  the (IDN-converting) work is not done twice.
  """
  @spec storage_key(term(), {:ok, parts()} | {:error, error()}) :: String.t() | nil
  def storage_key(input, normalized) when is_binary(input) do
    if storable?(input) do
      case normalized do
        {:ok, %{email: email}} -> String.slice(email, 0, 320)
        {:error, :empty} -> nil
        {:error, _} -> input |> String.trim() |> String.slice(0, 320)
      end
    end
  end

  def storage_key(_input, _normalized), do: nil

  @doc """
  The local part without its `+tag`: everything from the first `+` is a tag -
  unless nothing would be left.
  """
  @spec strip_tag(String.t()) :: String.t()
  def strip_tag(local) do
    case String.split(local, "+", parts: 2) do
      [base, _tag] when base != "" -> base
      _ -> local
    end
  end

  defp storable?(input), do: String.valid?(input) and not String.contains?(input, <<0>>)

  defp split(""), do: {:error, :empty}

  defp split(trimmed) do
    case String.split(trimmed, "@") do
      [local, domain] when local != "" and domain != "" -> {:ok, local, domain}
      _ -> {:error, :bad_at}
    end
  end

  defp build(local, domain) do
    with {:ok, ascii} <- to_ascii(String.downcase(domain)) do
      {:ok, %{email: local <> "@" <> ascii, local: local, domain: ascii}}
    end
  end

  defp to_ascii(domain) do
    if String.match?(domain, ~r/\A[\x00-\x7f]*\z/) do
      {:ok, domain}
    else
      punycode(domain)
    end
  end

  defp punycode(domain) do
    {:ok, domain |> String.to_charlist() |> :idna.encode(uts46: true) |> to_string()}
  catch
    _kind, _reason -> {:error, :bad_idn}
  end
end
