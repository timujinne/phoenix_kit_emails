defmodule PhoenixKit.Modules.Emails.Verification.Syntax do
  @moduledoc """
  Step 2 of the pipeline: a simplified RFC 5321/5322 check.

  Accepted: an ASCII dot-atom local part of at most 64 bytes, a domain of at
  least two LDH labels (each 1-63 bytes, no leading or trailing hyphen), and
  254 bytes overall. Not accepted, on purpose: quoted local parts, comments,
  display names, IP-literal domains and non-ASCII local parts (SMTPUTF8) - none
  of them is something a mailing list should be sending to.
  """

  @type detail ::
          :too_long
          | :local_too_long
          | :local_dots
          | :local_chars
          | :domain_no_dot
          | :domain_dots
          | :domain_label_too_long
          | :domain_chars

  @local_atom ~r/\A[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+\z/
  @domain_label ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @spec check(String.t(), String.t()) :: :ok | {:error, detail()}
  def check(local, domain) do
    cond do
      byte_size(local) + 1 + byte_size(domain) > 254 -> {:error, :too_long}
      byte_size(local) > 64 -> {:error, :local_too_long}
      true -> with :ok <- check_local(local), do: check_domain(domain)
    end
  end

  defp check_local(local) do
    atoms = String.split(local, ".")

    cond do
      "" in atoms -> {:error, :local_dots}
      Enum.all?(atoms, &Regex.match?(@local_atom, &1)) -> :ok
      true -> {:error, :local_chars}
    end
  end

  defp check_domain(domain) do
    labels = String.split(domain, ".")

    cond do
      "" in labels -> {:error, :domain_dots}
      length(labels) < 2 -> {:error, :domain_no_dot}
      Enum.any?(labels, &(byte_size(&1) > 63)) -> {:error, :domain_label_too_long}
      Enum.all?(labels, &Regex.match?(@domain_label, &1)) -> :ok
      true -> {:error, :domain_chars}
    end
  end
end
