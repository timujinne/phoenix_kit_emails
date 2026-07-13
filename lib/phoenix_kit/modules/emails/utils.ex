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
end
