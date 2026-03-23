defmodule PhoenixKitEmailsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails

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
end
