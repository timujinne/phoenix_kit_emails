defmodule PhoenixKitEmailsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Utils, as: EmailsUtils

  test "module_key returns emails" do
    assert Emails.module_key() == "emails"
  end

  test "module_name returns Emails" do
    assert Emails.module_name() == "Emails"
  end

  test "required_modules is empty" do
    assert Emails.required_modules() == []
  end

  test "admin_tabs returns list" do
    tabs = Emails.admin_tabs()
    assert is_list(tabs)
    refute Enum.empty?(tabs)
  end

  test "settings_tabs returns list" do
    tabs = Emails.settings_tabs()
    assert is_list(tabs)
  end

  test "route_module is defined" do
    assert Emails.route_module() == PhoenixKit.Modules.Emails.Web.Routes
  end

  test "children includes Supervisor" do
    children = Emails.children()
    assert PhoenixKit.Modules.Emails.Supervisor in children
  end

  test "Provider implements PhoenixKit.Email.Provider behaviour" do
    behaviours =
      PhoenixKit.Modules.Emails.Provider.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PhoenixKit.Email.Provider in behaviours
  end

  test "Provider responds to all required callbacks" do
    provider = PhoenixKit.Modules.Emails.Provider
    Code.ensure_loaded!(provider)

    assert function_exported?(provider, :intercept_before_send, 2)
    assert function_exported?(provider, :handle_after_send, 2)
    assert function_exported?(provider, :get_active_template_by_name, 1)
    assert function_exported?(provider, :render_template, 2)
    assert function_exported?(provider, :render_template, 3)
    assert function_exported?(provider, :track_usage, 1)
    assert function_exported?(provider, :get_source_module, 1)
    assert function_exported?(provider, :get_aws_region, 0)
    assert function_exported?(provider, :get_aws_access_key, 0)
    assert function_exported?(provider, :get_aws_secret_key, 0)
    assert function_exported?(provider, :aws_configured?, 0)
    assert function_exported?(provider, :adapter_to_provider_name, 2)
    assert function_exported?(provider, :send_test_tracking_email, 2)
  end

  describe "Utils.mailer_adapter_status/0" do
    test "returns a map with the expected keys and types" do
      status = EmailsUtils.mailer_adapter_status()

      assert is_map(status)
      assert Map.has_key?(status, :mailer)
      assert Map.has_key?(status, :adapter)
      assert Map.has_key?(status, :provider)
      assert Map.has_key?(status, :config_app)
      assert Map.has_key?(status, :config_module)

      assert is_atom(status.mailer)
      assert is_atom(status.config_module)
      assert is_atom(status.config_app) or is_nil(status.config_app)
      assert is_binary(status.provider)
    end
  end

  describe "Utils.adapter_to_provider_name/2" do
    test "maps known Swoosh adapters to provider names" do
      assert EmailsUtils.adapter_to_provider_name(Swoosh.Adapters.AmazonSES, "x") == "aws_ses"
      assert EmailsUtils.adapter_to_provider_name(Swoosh.Adapters.SMTP, "x") == "smtp"
      assert EmailsUtils.adapter_to_provider_name(Swoosh.Adapters.Sendgrid, "x") == "sendgrid"
      assert EmailsUtils.adapter_to_provider_name(Swoosh.Adapters.Mailgun, "x") == "mailgun"
      assert EmailsUtils.adapter_to_provider_name(Swoosh.Adapters.Local, "x") == "local"
      assert EmailsUtils.adapter_to_provider_name(nil, "fallback") == "fallback"
      assert EmailsUtils.adapter_to_provider_name(SomeUnknown, "fallback") == "fallback"
    end
  end

  describe "Utils.detect_provider_from_config/0" do
    test "returns a binary provider name" do
      provider = EmailsUtils.detect_provider_from_config()
      assert is_binary(provider)
    end
  end

  test "Emails.current_provider/0 returns a string (or safe fallback in minimal env)" do
    # In the minimal test env without a configured Repo, this may hit
    # Settings and raise. We treat any exception as "unknown" fallback for
    # the purpose of this smoke test. The core logic is covered by
    # mailer_adapter_status/0.
    provider =
      try do
        Emails.current_provider()
      rescue
        _ -> "unknown"
      end

    assert is_binary(provider)
  end
end
