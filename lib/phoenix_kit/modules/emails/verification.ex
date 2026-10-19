defmodule PhoenixKit.Modules.Emails.Verification do
  @moduledoc """
  E-mail address verification: the public API of the engine.

  An address goes through `Verification.Pipeline` (normalise, syntax, TLD,
  disposable domains, free/role flags, DNS MX, optional SMTP) and the verdict -
  a `Verification.Result` - is stored, one row per address, in
  `phoenix_kit_email_verifications`. Callers pass plain lists of addresses; the
  engine knows nothing about who owns them (CRM contacts, newsletter
  recipients, ...).

  Without SMTP an address that passes every step is `not_sure` at level `"mx"`:
  its domain accepts mail, the mailbox is unchecked. `"valid"` only ever comes
  from an SMTP probe, which is off by default (`email_verify_smtp_enabled`) and,
  in this release, has no client behind it.

  See `docs/superpowers/specs/2026-10-19-email-verification.md` and
  `Verification.Config` for the settings.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Result

  @type summary :: %{
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          temp: non_neg_integer(),
          not_sure: non_neg_integer(),
          unchecked: non_neg_integer()
        }

  @doc """
  Whether verification is switched on (`email_verify_enabled`).

  Defaults to `true`: the checks that run by default (syntax, word lists, DNS)
  are passive and cost nothing to leave available. It deliberately does not
  look at `email_verify_smtp_enabled` - the SMTP step is a separate, riskier
  switch - nor at `email_enabled`, which gates sending. `false` if settings
  cannot be read.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: Config

  @doc """
  Verifies one address synchronously and stores the verdict.

  A stored verdict younger than `email_verify_ttl_result_days` is returned as is
  (`source: "cache"`) - except a `"temp"` one, which is always re-run. The MX
  answer is cached per domain either way.

  Options: `:force` (re-run even if a stored verdict is fresh), `:resolver` and
  `:smtp` (override the configured implementations).
  """
  @spec verify(term(), keyword()) :: {:ok, Result.t()} | {:error, Ecto.Changeset.t()}
  def verify(email, opts \\ []) do
    case stored_fresh(email, opts) do
      %Result{} = result -> {:ok, result}
      nil -> email |> Pipeline.run(opts) |> persist()
    end
  end

  @doc """
  The stored verdicts for `emails`, keyed by the address as given.
  Addresses never verified are absent.
  """
  @spec results_for([term()]) :: %{String.t() => Result.t()}
  def results_for(emails) do
    keyed = for email <- emails, key = Normalizer.storage_key(email), do: {email, key}

    by_key =
      keyed
      |> Enum.map(fn {_email, key} -> key end)
      |> Enum.uniq()
      |> fetch_rows()
      |> Map.new(&{String.downcase(&1.email), %{&1 | source: "cache"}})

    for {email, key} <- keyed, result = by_key[String.downcase(key)], into: %{} do
      {email, result}
    end
  end

  @doc """
  Counts `emails` by stored status. `unchecked` are the ones with no verdict.
  An address listed twice counts twice.
  """
  @spec summary([term()]) :: summary()
  def summary(emails) do
    results = results_for(emails)
    counts = emails |> Enum.map(&status_of(results, &1)) |> Enum.frequencies()

    for status <- [:valid, :invalid, :temp, :not_sure, :unchecked], into: %{} do
      {status, Map.get(counts, status, 0)}
    end
  end

  ## --- Internals ---

  defp status_of(results, email) do
    case Map.fetch(results, email) do
      {:ok, %Result{status: status}} -> String.to_existing_atom(status)
      :error -> :unchecked
    end
  end

  defp stored_fresh(email, opts) do
    with false <- Keyword.get(opts, :force, false),
         key when is_binary(key) <- Normalizer.storage_key(email),
         [row] <- fetch_rows([key]),
         true <- row.status != "temp" and fresh?(row) do
      %{row | source: "cache"}
    else
      _ -> nil
    end
  end

  defp fresh?(%Result{checked_at: %DateTime{} = at}) do
    DateTime.diff(PhoenixKit.Utils.Date.utc_now(), at, :second) < Config.ttl_seconds(:result)
  end

  defp fresh?(_result), do: false

  defp fetch_rows([]), do: []

  defp fetch_rows(keys) do
    repo().all(from(r in Result, where: fragment("? = ANY(?::citext[])", r.email, ^keys)))
  end

  # A blank input has nothing to key a row on: report it, store nothing.
  defp persist(%Result{email: nil} = result), do: {:ok, result}

  defp persist(%Result{} = result) do
    attrs = Map.take(result, [:email, :domain, :status, :reason, :level, :catch_all] ++ flags())
    attrs = Map.merge(attrs, Map.take(result, [:mx, :log, :checked_at]))

    changeset = Result.changeset(%Result{}, attrs)

    on_conflict =
      from(r in Result,
        update: [
          set: [
            domain: ^result.domain,
            status: ^result.status,
            reason: ^result.reason,
            level: ^result.level,
            catch_all: ^result.catch_all,
            free: ^result.free,
            role: ^result.role,
            disposable: ^result.disposable,
            mx: ^result.mx,
            log: ^result.log,
            checked_at: ^result.checked_at,
            updated_at: ^result.checked_at
          ],
          inc: [attempts: 1]
        ]
      )

    case repo().insert(changeset,
           on_conflict: on_conflict,
           conflict_target: :email,
           returning: true
         ) do
      {:ok, stored} -> {:ok, %{stored | source: "direct"}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp flags, do: [:free, :role, :disposable]

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
