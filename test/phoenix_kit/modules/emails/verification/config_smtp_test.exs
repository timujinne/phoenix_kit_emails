defmodule PhoenixKit.Modules.Emails.Verification.ConfigSmtpTest do
  @moduledoc """
  The settings of the SMTP stage: the mode, the MAIL FROM rules
  (override wins, else the site's sender, placeholders are "not
  configured") and the typed getters with their defaults.
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Smtp.Direct
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
      Settings.update_boolean_setting_with_module(
        "email_verify_smtp_enabled",
        true,
        "email_system"
      )

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
      put("from_email", "mail@acme-mail.test")

      assert Config.smtp_mail_from() == {"mail@acme-mail.test", :site_sender}
      assert Config.site_sender_address() == "mail@acme-mail.test"
    end

    test "a valid override wins over the site sender" do
      put("from_email", "mail@acme-mail.test")
      put("email_verify_smtp_mail_from", "  verify@acme-mail.test ")

      assert Config.smtp_mail_from() == {"verify@acme-mail.test", :override}
      assert Config.smtp_mail_from_override() == "verify@acme-mail.test"
    end

    test "an override alone is enough" do
      put("email_verify_smtp_mail_from", "verify@acme-mail.test")
      assert Config.smtp_mail_from() == {"verify@acme-mail.test", :override}
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
        "@acme-mail.test",
        ""
      ]

      for value <- placeholders do
        put("from_email", value)
        assert Config.smtp_mail_from() == {nil, :none}, "site sender #{inspect(value)}"
      end
    end

    test "a placeholder override does not shadow a good site sender" do
      put("from_email", "mail@acme-mail.test")

      for value <- ["verify@localhost", "verify@example.com", "garbage"] do
        put("email_verify_smtp_mail_from", value)
        assert Config.smtp_mail_from() == {"mail@acme-mail.test", :site_sender}, inspect(value)
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

    test "the address is normalised: the domain lowercase, punycode, the local part as typed" do
      put("from_email", "  Mail@Acme-Mail.TEST ")
      assert Config.smtp_mail_from() == {"Mail@acme-mail.test", :site_sender}
      assert Config.site_sender_address() == "Mail@acme-mail.test"

      put("email_verify_smtp_mail_from", "verify@München.DE")
      assert Config.smtp_mail_from() == {"verify@xn--mnchen-3ya.de", :override}
    end

    test "a non-ASCII local part would need SMTPUTF8: not usable" do
      put("from_email", "почта@acme-mail.test")
      assert Config.smtp_mail_from() == {nil, :none}
      assert Config.site_sender_address() == nil

      put("email_verify_smtp_mail_from", "büro@acme-mail.test")
      assert Config.smtp_mail_from() == {nil, :none}
    end

    test "a non-ASCII override falls back to the site sender" do
      put("from_email", "mail@acme-mail.test")
      put("email_verify_smtp_mail_from", "büro@acme-mail.test")
      assert Config.smtp_mail_from() == {"mail@acme-mail.test", :site_sender}
    end
  end

  describe "smtp_helo/0" do
    test "a host name or an address literal is passed on" do
      for value <- ["mx.example.ee", "MX-1.Example.EE", "host", "a.b-c.d", "[203.0.113.9]"] do
        put("email_verify_smtp_helo", value)
        assert Config.smtp_helo() == value, inspect(value)
      end
    end

    test "anything that is not a plain host name is automatic (nil)" do
      too_long = String.duplicate("a.", 128) <> "ee"
      long_label = String.duplicate("a", 64) <> ".ee"

      for value <- [
            "mx.example.ee\r\nDATA",
            "mx.example.ee\nRCPT TO:<a@b.ee>",
            "mx example.ee",
            "mx\texample.ee",
            "mx\u0001.example.ee",
            "mx.example.ee>",
            "-mx.example.ee",
            "mx-.example.ee",
            "mx..example.ee",
            ".example.ee",
            "mx_1.example.ee",
            "münchen.de",
            "[203.0.113.256]",
            "[203.0.113.9",
            "[203.0.113.9]x",
            "[IPv4:203.0.113.9]",
            "[not an ip]",
            long_label,
            too_long
          ] do
        put("email_verify_smtp_helo", value)
        assert Config.smtp_helo() == nil, inspect(value)
      end
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
      assert Config.smtp_queue_max_age_s() == 48 * 3_600
      assert Config.claim_dns_budget_ms() == 10_000
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
      put("email_verify_smtp_helo", " mail.acme-mail.test ")
      put("email_verify_smtp_selftest_host", "mx.acme-mail.test")
      put("email_verify_rcpt_per_session", "4")
      put("email_verify_domain_interval_s", "30")
      put("email_verify_smtp_idle_poll_s", "5")
      put("email_verify_domain_pause_min", "10")
      put("email_verify_smtp_queue_max_age_h", "6")
      put("email_verify_smtp_claim_dns_budget_ms", "2500")

      assert Config.smtp_queue_max_age_s() == 6 * 3_600
      assert Config.claim_dns_budget_ms() == 2_500
      assert Config.smtp_helo() == "mail.acme-mail.test"
      assert Config.smtp_selftest_host_setting() == "mx.acme-mail.test"
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

  describe "the lease of a session" do
    test "the floor is the session's hard limit plus a margin" do
      assert Config.session_hard_limit_s() == 240
      assert Config.smtp_lease_floor_s() == Config.session_hard_limit_s() + 60
      assert Config.smtp_lease_floor_s() == 300
    end

    test "the hard limit is the one both runners enforce" do
      source = File.read!("priv/smtp_runner/pk-smtp-runner.ps1")
      assert [_, ms] = Regex.run(~r/HardMs\s*=\s*(\d+)/, source)
      assert String.to_integer(ms) == Config.session_hard_limit_s() * 1000

      assert Direct.hard_limit_ms() ==
               Config.session_hard_limit_s() * 1000
    end

    test "a setting below the floor reads as the floor, one above it as itself" do
      for below <- ["1", "120", "299"] do
        put("email_verify_smtp_lease_s", below)
        assert Config.smtp_lease_s() == Config.smtp_lease_floor_s(), below
      end

      put("email_verify_smtp_lease_s", "300")
      assert Config.smtp_lease_s() == 300

      put("email_verify_smtp_lease_s", "900")
      assert Config.smtp_lease_s() == 900
    end
  end

  describe "what the settings form checks with" do
    test "usable_sender_address/1 normalises an address and refuses placeholders" do
      assert Config.usable_sender_address("Verify@Acme-Mail.TEST") ==
               {:ok, "Verify@acme-mail.test"}

      for bad <- ["verify", "noreply@localhost", "x@example.com", "x@host", "", nil, 5] do
        assert Config.usable_sender_address(bad) == :error, inspect(bad)
      end
    end

    test "helo_name?/1 takes host names and address literals, nothing else" do
      assert Config.helo_name?("mx.acme-mail.test")
      assert Config.helo_name?("[203.0.113.9]")

      for bad <- ["", "mx host", "mx.ee\r\nDATA", "-mx.ee", "a..b", nil, 5] do
        refute Config.helo_name?(bad), inspect(bad)
      end
    end
  end
end
