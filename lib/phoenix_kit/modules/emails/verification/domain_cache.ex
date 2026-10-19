defmodule PhoenixKit.Modules.Emails.Verification.DomainCache do
  @moduledoc """
  The persistent per-domain cache (`phoenix_kit_email_verify_domains`).

  One row per domain; every cached fact has its own timestamp and so its own
  TTL (`Config.ttl_seconds/1`). In this stage only the MX answer is used - the
  catch-all, greylist and throttling columns belong to the SMTP stage and are
  left untouched.

  The `mx` column holds either `%{"hosts" => [...], "implicit" => bool}` or,
  for a definitive negative answer, `%{"error" => "nxdomain"}` (also
  `"no_records"`, `"null_mx"`). Transient failures (`:servfail`, `:timeout`)
  are never stored: an unanswered question must be asked again.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Resolver

  @primary_key {:domain, :string, autogenerate: false}

  @type t :: %__MODULE__{}
  @type kind :: Config.ttl_kind()

  schema "phoenix_kit_email_verify_domains" do
    field(:mx, :map)
    field(:has_mx, :boolean)
    field(:mx_checked_at, :utc_datetime)
    field(:catch_all, :boolean)
    field(:catch_all_checked_at, :utc_datetime)
    field(:grey_message, :string)
    field(:grey_at, :utc_datetime)
    field(:last_smtp_at, :utc_datetime)
    field(:blocks, :map, default: %{})
    field(:paused_until, :utc_datetime)
  end

  @definitive_errors ~w(nxdomain no_records null_mx)

  @doc """
  The cached MX resolution of `domain`, if there is a fresh one.

  Returns `{:hit, {:ok, resolution}}` or `{:hit, {:error, reason}}` in the shape
  of `Resolver.resolve/2`, or `:miss`.
  """
  @spec fetch_mx(String.t(), DateTime.t()) ::
          {:hit, {:ok, Resolver.resolution()} | {:error, Resolver.resolve_error()}} | :miss
  def fetch_mx(domain, now) do
    case repo().get(__MODULE__, domain) do
      %__MODULE__{mx: %{} = mx, mx_checked_at: %DateTime{}} = row ->
        if fresh?(row, ttl_kind(row), now), do: decode(mx), else: :miss

      _ ->
        :miss
    end
  end

  @doc """
  Remembers a definitive MX answer. Transient errors are ignored.
  """
  @spec store_mx(String.t(), {:ok, Resolver.resolution()} | {:error, term()}, DateTime.t()) ::
          :ok
  def store_mx(domain, {:ok, resolution}, now) do
    upsert(domain, %{
      mx: %{
        "hosts" => Enum.map(resolution.hosts, &%{"host" => &1.host, "pref" => &1.pref}),
        "implicit" => resolution.implicit
      },
      has_mx: true,
      mx_checked_at: now
    })
  end

  def store_mx(domain, {:error, reason}, now) when reason in [:nxdomain, :no_records, :null_mx] do
    upsert(domain, %{mx: %{"error" => Atom.to_string(reason)}, has_mx: false, mx_checked_at: now})
  end

  def store_mx(_domain, {:error, _transient}, _now), do: :ok

  @doc """
  Whether the fact of the given `kind` on `row` is still within its TTL.

  `:mx` and `:no_mx` read `mx_checked_at`, `:catch_all` reads
  `catch_all_checked_at`, `:grey` reads `grey_at`.
  """
  @spec fresh?(t(), kind(), DateTime.t()) :: boolean()
  def fresh?(%__MODULE__{} = row, kind, now) when kind in [:mx, :no_mx, :catch_all, :grey] do
    case checked_at(row, kind) do
      %DateTime{} = at -> DateTime.diff(now, at, :second) < Config.ttl_seconds(kind)
      nil -> false
    end
  end

  defp checked_at(row, kind) when kind in [:mx, :no_mx], do: row.mx_checked_at
  defp checked_at(row, :catch_all), do: row.catch_all_checked_at
  defp checked_at(row, :grey), do: row.grey_at

  defp ttl_kind(%__MODULE__{has_mx: true}), do: :mx
  defp ttl_kind(%__MODULE__{}), do: :no_mx

  defp decode(%{"error" => error}) when error in @definitive_errors,
    do: {:hit, {:error, String.to_existing_atom(error)}}

  defp decode(%{"hosts" => [_ | _] = hosts} = mx) do
    hosts = Enum.map(hosts, &%{host: &1["host"], pref: &1["pref"]})
    {:hit, {:ok, %{hosts: hosts, implicit: mx["implicit"] == true}}}
  end

  defp decode(_unreadable), do: :miss

  defp upsert(domain, fields) do
    {:ok, _} =
      repo().insert(struct(__MODULE__, Map.put(fields, :domain, domain)),
        on_conflict: {:replace, Map.keys(fields)},
        conflict_target: :domain
      )

    :ok
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
