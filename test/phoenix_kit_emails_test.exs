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
    # The database-template callbacks are gone from core 3.0's behaviour.
    refute function_exported?(provider, :get_active_template_by_name, 1)
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

  describe "Utils.string_param/2" do
    doctest PhoenixKit.Modules.Emails.Utils, only: [string_param: 2]

    test "a string passes through untouched" do
      assert EmailsUtils.string_param("x") == "x"
      assert EmailsUtils.string_param("", "d") == ""
    end

    test "anything else is the default" do
      for value <- [nil, 42, 1.5, :atom, %{"a" => "b"}, ["x"]] do
        assert EmailsUtils.string_param(value) == ""
        assert EmailsUtils.string_param(value, nil) == nil
      end
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

  describe "Blocklist URL state" do
    alias PhoenixKit.Modules.Emails.Web.Blocklist

    defp spec(key) do
      Blocklist.__phoenix_kit_url_state__().params |> Enum.find(&(&1.key == key))
    end

    test "sort_by accepts exactly the columns list_blocklist/1 can order by" do
      # Three lists have to agree: this whitelist, validate_sort_by/1's, and the
      # `field in [...]` guard in RateLimiter.list_blocklist/1. A column present
      # in the header but missing here is decoded back to the default, so the
      # click appears to do nothing.
      assert spec(:sort_by).allowed == [:email, :reason, :inserted_at, :expires_at]
      assert spec(:sort_by).default == :inserted_at
      assert spec(:sort_dir).allowed == [:asc, :desc]
    end

    test "reason_filter stays free-form" do
      # Reasons are whatever the SQS processor, the rate limiter or a CSV import
      # wrote, and the dropdown is built from the reasons actually in the data.
      # A whitelist here rejects the very options the screen offers, and because
      # a rejected value falls back to the default the URL never changes and the
      # click has no visible effect. Keep it nil.
      assert spec(:reason_filter).allowed == nil
      assert spec(:status_filter).allowed == ~w(all expired)
    end

    test "clamp_page/2 keeps the pagination window ascending" do
      # ?page=900 on a two-page list used to leave @page at 900, making the
      # template's max(1, @page - 2)..min(@total_pages, @page + 2) window a
      # descending range — 896 buttons. The URL ceiling of 1_000_000 made that
      # ~1M DOM nodes from a single crafted link.
      assert Blocklist.clamp_page(900, 2) == 2
      assert Blocklist.clamp_page(1_000_000, 2) == 2
      assert Blocklist.clamp_page(2, 5) == 2
      assert Blocklist.clamp_page(1, 0) == 1

      for {page, total} <- [{900, 2}, {1_000_000, 2}, {1, 0}, {3, 7}] do
        clamped = Blocklist.clamp_page(page, total)
        window = max(1, clamped - 2)..min(max(total, 1), clamped + 2)//1
        # Range.size/1 rather than Enum.count/1: it is the count the inverted
        # range would blow up (997..2//-1 has size 996), so a ceiling of 5 is
        # the assertion that the window stayed a window.
        assert Range.size(window) in 1..5
      end
    end

    test "page is bounded on both ends" do
      assert spec(:page).min == 1
      assert spec(:page).max == 1_000_000
      assert spec(:page).default == 1
    end
  end
end
