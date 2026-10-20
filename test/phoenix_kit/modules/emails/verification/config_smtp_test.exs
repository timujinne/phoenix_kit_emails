defmodule PhoenixKit.Modules.Emails.Verification.ConfigSmtpTest do
  @moduledoc """
  The settings of the SMTP stage: the mode, the MAIL FROM rules of the owner's
  decision (override wins, else the site's sender, placeholders are "not
  configured") and the typed getters with their defaults.
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Settings

  defp put(key, value), do: Settings.update_setting_with_module(key, value, "email_system")

  describe "smtp_mode/0" do
    test "is off by default" do
      assert Config.smtp_mode() == "off"
      assert Config.smtp_mode_setting() == "off"
      refute Config.smtp_enabled?()
    end

    test "reads runner and local, ignoring case and spaces" do
      put("email_verify_smtp_mode", " Runner ")
      assert Config.smtp_mode() == "runner"
      assert Config.smtp_enabled?()

      put("email_verify_smtp_mode", "local")
      assert Config.smtp_mode() == "local"
    end

    test "anything else is off" do
      for bad <- ["", "on", "true", "remote", "RUNNER2"] do
        put("email_verify_smtp_mode", bad)
        assert Config.smtp_mode() == "off", inspect(bad)
      end
    end

    test "the old boolean switch does nothing any more" do
      Settings.update_boolean_setting_with_module("email_verify_smtp_enabled", true, "email_system")
      assert Config.smtp_mode() == "off"
    end

    test "the core of the test run has the machine API, so runner mode is available" do
      assert Config.machine_api_available?()
    end
  end

  describe "smtp_mail_from/0" do
    test "with nothing configured the site sender is the localhost placeholder: no MAIL FROM" do
      assert Config.smtp_mail_from() == {nil, :none}
      assert Config.smtp_mail_from_override() == ""
      assert Config.site_sender_address() == nil
    end

    test "the site's configured sender is the default" do
      put("from_email", "mail@hydroforce.ee")

      assert Config.smtp_mail_from() == {"mail@hydroforce.ee", :site_sender}
      assert Config.site_sender_address() == "mail@hydroforce.ee"
    end

    test "a valid override wins over the site sender" do
      put("from_email", "mail@hydroforce.ee")
      put("email_verify_smtp_mail_from", "  verify@hydroforce.ee ")

      assert Config.smtp_mail_from() == {"verify@hydroforce.ee", :override}
      assert Config.smtp_mail_from_override() == "verify@hydroforce.ee"
    end

    test "an override alone is enough" do
      put("email_verify_smtp_mail_from", "verify@hydroforce.ee")
      assert Config.smtp_mail_from() == {"verify@hydroforce.ee", :override}
    end

    test "placeholder and invalid values count as not configured" do
      placeholders = [
        "noreply@localhost",
        "me@example.com",
        "me@example.org",
        "me@EXAMPLE.net",
        "me@mail.example.com",
        "me@intranet",
        "not an address",
        "a@@b.ee",
        "@hydroforce.ee",
        ""
      ]

      for value <- placeholders do
        put("from_email", value)
        assert Config.smtp_mail_from() == {nil, :none}, "site sender #{inspect(value)}"
      end
    end

    test "a placeholder override does not shadow a good site sender" do
      put("from_email", "mail@hydroforce.ee")

      for value <- ["verify@localhost", "verify@example.com", "garbage"] do
        put("email_verify_smtp_mail_from", value)
        assert Config.smtp_mail_from() == {"mail@hydroforce.ee", :site_sender}, inspect(value)
      end
    end

    test "a placeholder override and a placeholder site sender: no MAIL FROM" do
      put("email_verify_smtp_mail_from", "verify@example.com")
      assert Config.smtp_mail_from() == {nil, :none}
    end

    test "a domain that merely contains example is a real domain" do
      put("from_email", "mail@myexample.com")
      assert Config.smtp_mail_from() == {"mail@myexample.com", :site_sender}
    end
  end

  describe "typed getters and their defaults" do
    test "defaults" do
      assert Config.smtp_helo() == nil
      assert Config.smtp_selftest_host_setting() == nil
      assert Config.rcpt_per_session() == 10
      assert Config.domain_interval_s() == 10
      assert Config.grey_retry_minutes() == 20
      assert Config.grey_max_attempts() == 3
      assert Config.smtp_lease_s() == 300
      assert Config.smtp_max_attempts() == 5
      assert Config.smtp_connect_timeout_s() == 20
      assert Config.smtp_read_timeout_s() == 30
      assert Config.idle_poll_s() == 30
      assert Config.domain_block_threshold() == 2
      assert Config.domain_block_window_s() == 3_600
      assert Config.domain_pause_s() == 3_600
      assert Config.runner_fail_sessions() == 5
      assert Config.runner_fail_domains() == 3
      assert Config.runner_pause_s() == 3_600
    end

    test "settings override them" do
      put("email_verify_smtp_helo", " mail.hydroforce.ee ")
      put("email_verify_smtp_selftest_host", "mx.hydroforce.ee")
      put("email_verify_rcpt_per_session", "4")
      put("email_verify_domain_interval_s", "30")
      put("email_verify_smtp_idle_poll_s", "5")
      put("email_verify_domain_pause_min", "10")

      assert Config.smtp_helo() == "mail.hydroforce.ee"
      assert Config.smtp_selftest_host_setting() == "mx.hydroforce.ee"
      assert Config.rcpt_per_session() == 4
      assert Config.domain_interval_s() == 30
      assert Config.idle_poll_s() == 5
      assert Config.domain_pause_s() == 600
    end

    test "a blank helo is auto, junk numbers are the default, a session never exceeds 100 addresses" do
      put("email_verify_smtp_helo", "   ")
      put("email_verify_domain_interval_s", "soon")
      put("email_verify_smtp_lease_s", "0")
      put("email_verify_rcpt_per_session", "5000")

      assert Config.smtp_helo() == nil
      assert Config.domain_interval_s() == 10
      assert Config.smtp_lease_s() == 300
      assert Config.rcpt_per_session() == 100
    end
  end
end
