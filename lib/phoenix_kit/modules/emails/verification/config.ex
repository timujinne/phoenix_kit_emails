defmodule PhoenixKit.Modules.Emails.Verification.Config do
  @moduledoc """
  Reads the verification engine's configuration.

  Everything an operator can change lives in PhoenixKit settings (module
  `"email_system"`, prefix `email_verify_`); the two behaviour implementations
  and the external lists directory can also be set in the application env
  (`config :phoenix_kit_emails, ...`), which is what tests and host apps with
  private word lists use.

  ## Settings

    * `email_verify_enabled` - the feature switch (default `true`)
    * `email_verify_smtp_enabled` - run the SMTP step at all (default `false`)
    * `email_verify_ttl_mx_hours` - cached MX answer (default `24`)
    * `email_verify_ttl_no_mx_hours` - cached "no MX / no such domain" (default `24`)
    * `email_verify_ttl_catch_all_days` - cached catch-all probe (default `7`)
    * `email_verify_ttl_grey_hours` - cached greylist marker (default `24`)
    * `email_verify_ttl_result_days` - a stored verdict is reused this long (default `30`)
    * `email_verify_dns_timeout_ms` - per DNS query (default `3000`)
    * `email_verify_disposable_status` - the status of an address on a disposable
      domain: `"invalid"` (default) or `"temp"` (what LetsExtract does); any other
      value counts as `"invalid"`
    * `email_verify_dns_max_attempts` - how many times a batch job tries an address
      whose DNS lookup failed transiently before keeping the `temp` verdict (default `3`)
    * `email_verify_grey_retry_minutes` - least wait before a greylisted address is
      tried again in a batch; the wait is picked between this and twice this
      (default `15`)
    * `email_verify_grey_max_attempts` - greylist attempts before the `temp` verdict
      is kept (default `3`)
    * `email_verify_lists_dir` - optional external dictionary directory

  ## Application env (`:phoenix_kit_emails`)

    * `:verification_resolver` - a `Verification.Resolver` module (default `Resolver.Inet`)
    * `:verification_smtp` - a `Verification.Smtp` module (default `Smtp.Disabled`)
    * `:verification_lists_dir` - external dictionary directory; wins over the setting
  """

  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKit.Modules.Emails.Verification.Smtp
  alias PhoenixKit.Settings

  @type ttl_kind :: :mx | :no_mx | :catch_all | :grey | :result

  @default_dns_timeout_ms 3_000

  @doc "Whether the verification feature is switched on (default `true`)."
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting("email_verify_enabled", true)
  rescue
    _ -> false
  end

  @doc "Whether the SMTP step runs at all (default `false`)."
  @spec smtp_enabled?() :: boolean()
  def smtp_enabled? do
    Settings.get_boolean_setting("email_verify_smtp_enabled", false)
  rescue
    _ -> false
  end

  @doc "How long a cached fact (or a stored verdict) stays fresh, in seconds."
  @spec ttl_seconds(ttl_kind()) :: pos_integer()
  def ttl_seconds(:mx), do: hours("email_verify_ttl_mx_hours", 24)
  def ttl_seconds(:no_mx), do: hours("email_verify_ttl_no_mx_hours", 24)
  def ttl_seconds(:grey), do: hours("email_verify_ttl_grey_hours", 24)
  def ttl_seconds(:catch_all), do: days("email_verify_ttl_catch_all_days", 7)
  def ttl_seconds(:result), do: days("email_verify_ttl_result_days", 30)

  @doc """
  The status a disposable-domain address gets: `"invalid"` (the default) or
  `"temp"`, from `email_verify_disposable_status` (case and surrounding spaces
  ignored; anything unrecognised, or an unreadable store, is `"invalid"`).
  """
  @spec disposable_status() :: String.t()
  def disposable_status do
    case Settings.get_setting("email_verify_disposable_status") do
      value when is_binary(value) ->
        if value |> String.trim() |> String.downcase() == "temp", do: "temp", else: "invalid"

      _ ->
        "invalid"
    end
  rescue
    _ -> "invalid"
  end

  @doc "How many attempts a batch job makes on an address whose DNS lookup fails transiently."
  @spec dns_max_attempts() :: pos_integer()
  def dns_max_attempts, do: positive_integer("email_verify_dns_max_attempts", 3)

  @doc "How many attempts a batch job makes on a greylisted address."
  @spec grey_max_attempts() :: pos_integer()
  def grey_max_attempts, do: positive_integer("email_verify_grey_max_attempts", 3)

  @doc "The least wait, in minutes, before a greylisted address is tried again."
  @spec grey_retry_minutes() :: pos_integer()
  def grey_retry_minutes, do: positive_integer("email_verify_grey_retry_minutes", 15)

  @doc "Timeout of one DNS query, in milliseconds."
  @spec dns_timeout_ms() :: pos_integer()
  def dns_timeout_ms do
    positive_integer("email_verify_dns_timeout_ms", @default_dns_timeout_ms)
  end

  @doc "The DNS resolver implementation."
  @spec resolver() :: module()
  def resolver do
    Application.get_env(:phoenix_kit_emails, :verification_resolver, Resolver.Inet)
  end

  @doc "The SMTP client implementation. The stub, until a real client exists."
  @spec smtp_client() :: module()
  def smtp_client do
    Application.get_env(:phoenix_kit_emails, :verification_smtp, Smtp.Disabled)
  end

  @doc "The external dictionary directory, or `nil`."
  @spec lists_dir() :: String.t() | nil
  def lists_dir do
    case lists_dir_lookup() do
      {:ok, dir} -> dir
      :error -> nil
    end
  end

  @doc """
  Like `lists_dir/0`, but says when the answer is not trustworthy: `:error`
  means the settings store could not be read (the database is not ready yet),
  which is not the same as "no directory configured" (`{:ok, nil}`).
  """
  @spec lists_dir_lookup() :: {:ok, String.t() | nil} | :error
  def lists_dir_lookup do
    case Application.get_env(:phoenix_kit_emails, :verification_lists_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> setting_dir()
    end
  end

  defp setting_dir do
    case Settings.get_setting("email_verify_lists_dir") do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:ok, nil}
    end
  rescue
    _ -> :error
  end

  defp hours(key, default), do: positive_integer(key, default) * 3_600
  defp days(key, default), do: positive_integer(key, default) * 86_400

  defp positive_integer(key, default) do
    case Settings.get_integer_setting(key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  rescue
    _ -> default
  end
end
