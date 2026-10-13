defmodule PhoenixKit.Modules.Emails.Utils do
  @moduledoc """
  Utility functions for email handling in PhoenixKit.

  This module contains helper functions for email provider detection,
  configuration analysis, and other email-related utilities.
  """

  alias PhoenixKit.Config

  @doc """
  Converts Swoosh adapter module to provider name.

  Maps common Swoosh mailer adapters to standardized provider names
  used throughout PhoenixKit's email tracking system.

  ## Parameters

  - `adapter` - The Swoosh adapter module (e.g., Swoosh.Adapters.AmazonSES)
  - `default_name` - Default provider name to return if adapter is unknown

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.adapter_to_provider_name(Swoosh.Adapters.AmazonSES, "unknown")
      "aws_ses"

      iex> PhoenixKit.Modules.Emails.Utils.adapter_to_provider_name(Swoosh.Adapters.SMTP, "unknown")
      "smtp"

      iex> PhoenixKit.Modules.Emails.Utils.adapter_to_provider_name(Some.Custom.Adapter, "custom")
      "custom"
  """
  @spec adapter_to_provider_name(module() | nil, String.t()) :: String.t()
  def adapter_to_provider_name(adapter, default_name \\ "unknown") do
    case adapter do
      Swoosh.Adapters.AmazonSES -> "aws_ses"
      Swoosh.Adapters.SMTP -> "smtp"
      Swoosh.Adapters.Sendgrid -> "sendgrid"
      Swoosh.Adapters.Mailgun -> "mailgun"
      Swoosh.Adapters.Local -> "local"
      _ -> default_name
    end
  end

  @doc """
  A string from a LiveView event payload, or `default` when it holds anything
  else.

  A payload is whatever the client sends: a crafted event can put an integer,
  `nil`, a map or a list where the template puts a string, and `String.*`
  or `Date.from_iso8601/1` on that raises and takes the LiveView down. Callers
  that treat `""` as "nothing entered" get that for free from the default.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.string_param(" a ")
      " a "

      iex> PhoenixKit.Modules.Emails.Utils.string_param(42)
      ""

      iex> PhoenixKit.Modules.Emails.Utils.string_param(%{}, nil)
      nil
  """
  @spec string_param(term(), default) :: String.t() | default when default: term()
  def string_param(value, default \\ "")
  def string_param(value, _default) when is_binary(value), do: value
  def string_param(_value, default), do: default

  @doc """
  Detects email provider from application configuration.

  Analyzes the configured mailer adapter to determine which email
  provider is being used (AWS SES, SMTP, SendGrid, etc.).

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.detect_provider_from_config()
      "aws_ses"

      iex> PhoenixKit.Modules.Emails.Utils.detect_provider_from_config()
      "smtp"
  """
  @spec detect_provider_from_config() :: String.t()
  def detect_provider_from_config do
    mailer_adapter_status().provider
  end

  @doc """
  Reports exactly what mailer adapter is configured and where, for display
  in the admin UI.

  Mirrors `PhoenixKit.Mailer.deliver_email/2`'s own resolution logic (built-in
  vs. delegated mailer, config read from the right `otp_app`) so what this
  reports can never diverge from what actually sends mail — including the
  delegation-mode case where the host app supplies its own mailer module
  under its own `otp_app`.

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.mailer_adapter_status()
      %{mailer: PhoenixKit.Mailer, adapter: Swoosh.Adapters.AmazonSES,
        provider: "aws_ses", config_app: :phoenix_kit, config_module: PhoenixKit.Mailer}
  """
  @spec mailer_adapter_status() :: %{
          mailer: module(),
          adapter: module() | nil,
          provider: String.t(),
          config_app: atom(),
          config_module: module()
        }
  def mailer_adapter_status do
    mailer = PhoenixKit.Config.get_mailer()

    {config, config_app} =
      if mailer == PhoenixKit.Mailer do
        {Config.get(mailer, []), :phoenix_kit}
      else
        app = PhoenixKit.Config.get_parent_app()
        {Application.get_env(app, mailer, []), app}
      end

    adapter = Keyword.get(config, :adapter)

    %{
      mailer: mailer,
      adapter: adapter,
      provider: adapter_to_provider_name(adapter, "unknown"),
      config_app: config_app,
      config_module: mailer
    }
  end

  @doc """
  Reads an integer out of a URL or event param without ever raising.

  Params are whatever the address bar or a crafted event says, so
  `String.to_integer/1` on them is a crash waiting for `?page=abc`, and
  `Integer.parse/1` is one waiting for a `nil` or an integer payload. This
  accepts a whole integer string (surrounding whitespace allowed) or an
  integer; anything else — `nil`, `""`, `"abc"`, `"2abc"`, `"1.5"` — is
  `default`, which may be any term (`nil` lets a caller tell "no valid number"
  apart from every number).

  ## Options

    * `:min` — a value below it is `default` (`?page=0` is page 1, not page 0)
    * `:max` — a value above it is `default` too, the same rule core's
      `PhoenixKitWeb.Live.UrlState` applies to out-of-range integers
    * `:above_max` — `:clamp` turns a value above `:max` into `:max` instead
      (`?per_page=1000000` is the largest allowed page size); `:default`, the
      default, keeps the rule above

  ## Examples

      iex> PhoenixKit.Modules.Emails.Utils.parse_int("3", 1, min: 1)
      3

      iex> PhoenixKit.Modules.Emails.Utils.parse_int("abc", 1, min: 1)
      1

      iex> PhoenixKit.Modules.Emails.Utils.parse_int("500", 25, min: 1, max: 100)
      25

      iex> PhoenixKit.Modules.Emails.Utils.parse_int("500", 25, min: 1, max: 100, above_max: :clamp)
      100
  """
  @spec parse_int(term(), default, keyword()) :: integer() | default when default: term()
  def parse_int(value, default, opts \\ []) do
    case to_int(value) do
      nil -> default
      int -> bound(int, default, opts)
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  defp bound(int, default, opts) do
    min = Keyword.get(opts, :min)
    max = Keyword.get(opts, :max)

    cond do
      is_integer(min) and int < min ->
        default

      is_integer(max) and int > max ->
        above_max(Keyword.get(opts, :above_max, :default), max, default)

      true ->
        int
    end
  end

  defp above_max(:clamp, max, _default), do: max
  defp above_max(:default, _max, default), do: default

  # The farthest page a list URL may name. Not an overflow guard — offset tops
  # out near 1e8 here — but a bound on pointlessly distant pages, kept equal to
  # the ceiling core's UrlState puts on integer params so every list in this
  # module (Blocklist reads its page through UrlState) rejects the same URLs.
  @max_page 1_000_000

  @doc """
  The page number carried by a list's `?page` param: a whole number from 1 to
  #{@max_page}, or 1.

      iex> PhoenixKit.Modules.Emails.Utils.parse_page("3")
      3

      iex> PhoenixKit.Modules.Emails.Utils.parse_page("2000000")
      1
  """
  @spec parse_page(term()) :: pos_integer()
  def parse_page(value), do: parse_int(value, 1, min: 1, max: @max_page)

  @doc """
  The page a request can actually land on: `page` pulled into
  `1..max(total_pages, 1)`, so `?page=5` on a two-page list shows page 2.

      iex> PhoenixKit.Modules.Emails.Utils.clamp_page(5, 2)
      2

      iex> PhoenixKit.Modules.Emails.Utils.clamp_page(1, 0)
      1
  """
  @spec clamp_page(integer(), integer()) :: pos_integer()
  def clamp_page(page, total_pages) when is_integer(page) and is_integer(total_pages) do
    page |> max(1) |> min(max(total_pages, 1))
  end
end
