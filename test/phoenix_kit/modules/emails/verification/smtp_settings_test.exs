defmodule PhoenixKit.Modules.Emails.Verification.SmtpSettingsTest do
  @moduledoc """
  What the settings section writes: the mode (and the drain when it goes to `off`),
  the MAIL FROM override and the HELO name, and the numeric settings of the SMTP
  stage. A form is validated as a whole and written only when every field is fine.
  """

  # Not async: the drain takes the same advisory locks as the queue tests.
  use PhoenixKitEmails.DataCase, async: false

  import PhoenixKitEmails.Test.SmtpHelpers

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.SmtpSettings
  alias PhoenixKit.Settings
  alias PhoenixKitEmails.Test.FakeResolver

  describe "current/0" do
    test "the defaults of a fresh install" do
      current = SmtpSettings.current()

      assert current.mode == "off"
      assert current.mail_from == ""
      assert current.helo == ""
      assert current.selftest_host == ""

      assert current.numbers == %{
               "rcpt_per_session" => 10,
               "domain_interval_s" => 10,
               "grey_retry_minutes" => 20,
               "grey_max_attempts" => 3,
               "smtp_lease_s" => 300,
               "smtp_max_attempts" => 5,
               "smtp_connect_timeout_s" => 20,
               "smtp_read_timeout_s" => 30,
               "smtp_idle_poll_s" => 30,
               "domain_block_threshold" => 2,
               "domain_block_window_min" => 60,
               "domain_pause_min" => 60,
               "runner_fail_sessions" => 5,
               "runner_fail_domains" => 3,
               "runner_pause_min" => 60
             }
    end

    test "reads back what the getters read" do
      put("email_verify_domain_block_window_min", "30")
      put("email_verify_smtp_mail_from", "verify@acme-mail.test")

      current = SmtpSettings.current()

      assert current.numbers["domain_block_window_min"] == 30
      assert current.mail_from == "verify@acme-mail.test"
    end

    test "numbers lists the fields in the order of the form" do
      assert SmtpSettings.number_fields() |> Enum.take(3) ==
               ["rcpt_per_session", "domain_interval_s", "grey_retry_minutes"]
    end
  end

  describe "save_mode/1" do
    test "stores the three modes" do
      for mode <- ["local", "runner", "off"] do
        assert {:ok, %{mode: ^mode}} = SmtpSettings.save_mode(mode)
        assert Config.smtp_mode_setting() == mode
      end
    end

    test "refuses anything else and leaves the setting alone" do
      put("email_verify_smtp_mode", "local")

      for bad <- ["", "on", "RUNNER", nil, 1] do
        assert {:error, :invalid_mode} = SmtpSettings.save_mode(bad)
      end

      assert Config.smtp_mode_setting() == "local"
    end

    test "runner mode needs the machine API of core" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      assert {:error, :runner_unavailable} = SmtpSettings.save_mode("runner")
      assert Config.smtp_mode_setting() == "off"

      assert {:ok, %{mode: "local"}} = SmtpSettings.save_mode("local")
    end

    test "going to off settles the queued addresses as not checked by SMTP" do
      configure_runner_mode()
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})

      assert {:ok, _} = Verification.verify("info@#{domain}", smtp: :enqueue)
      assert SmtpQueue.counts().queued == 1

      assert {:ok, %{mode: "off", drained: 1}} = SmtpSettings.save_mode("off")

      assert SmtpQueue.counts().queued == 0
      email = "info@#{domain}"

      assert %{^email => %{status: "not_sure", reason: "smtp_disabled"}} =
               Verification.results_for([email])
    end

    test "switching between runner and local keeps the queue" do
      configure_runner_mode()
      domain = unique_domain()
      FakeResolver.put(domain, mx: {:ok, [%{host: "mx.#{domain}", pref: 10}]})
      assert {:ok, _} = Verification.verify("info@#{domain}", smtp: :enqueue)

      assert {:ok, %{mode: "local", drained: 0}} = SmtpSettings.save_mode("local")
      assert SmtpQueue.counts().queued == 1
    end
  end

  describe "save/1" do
    test "writes the sender, the HELO name and the numbers" do
      params =
        SmtpSettings.current()
        |> form()
        |> Map.merge(%{
          "mail_from" => " Verify@Acme-Mail.TEST ",
          "helo" => "mx.acme-mail.test",
          "rcpt_per_session" => "20",
          "domain_pause_min" => " 15 "
        })

      assert {:ok, _} = SmtpSettings.save(params)

      assert Config.smtp_mail_from() == {"Verify@acme-mail.test", :override}
      assert Config.smtp_helo() == "mx.acme-mail.test"
      assert Config.rcpt_per_session() == 20
      assert Config.domain_pause_s() == 15 * 60
    end

    test "empty sender and HELO clear the overrides" do
      put("from_email", "mail@acme-mail.test")
      put("email_verify_smtp_mail_from", "verify@acme-mail.test")
      put("email_verify_smtp_helo", "mx.acme-mail.test")

      params = SmtpSettings.current() |> form() |> Map.merge(%{"mail_from" => "", "helo" => ""})
      assert {:ok, _} = SmtpSettings.save(params)

      assert Config.smtp_mail_from() == {"mail@acme-mail.test", :site_sender}
      assert Config.smtp_helo() == nil
    end

    test "the self-test host is stored as given, empty clears it" do
      params = SmtpSettings.current() |> form() |> Map.put("selftest_host", "mx.acme-mail.test")
      assert {:ok, _} = SmtpSettings.save(params)
      assert Config.smtp_selftest_host_setting() == "mx.acme-mail.test"

      assert {:ok, _} = SmtpSettings.save(Map.put(params, "selftest_host", ""))
      assert Config.smtp_selftest_host_setting() == nil
    end

    test "a sender that is not an address is refused, a placeholder too" do
      for bad <- ["verify", "verify@", "a b@acme-mail.test", "noreply@localhost", "x@example.com"] do
        params = SmtpSettings.current() |> form() |> Map.put("mail_from", bad)
        assert {:error, %{"mail_from" => :address}} = SmtpSettings.save(params), bad
      end
    end

    test "a HELO name with a line break or a space is refused" do
      for bad <- ["mx.acme-mail.test\r\nDATA", "mx host", "-mx.ee", "a..b"] do
        params = SmtpSettings.current() |> form() |> Map.put("helo", bad)
        assert {:error, %{"helo" => :helo}} = SmtpSettings.save(params), inspect(bad)
      end
    end

    test "the self-test host follows the HELO rule" do
      params = SmtpSettings.current() |> form() |> Map.put("selftest_host", "mx host")
      assert {:error, %{"selftest_host" => :helo}} = SmtpSettings.save(params)
    end

    test "numbers must be whole and above zero" do
      for bad <- ["", "0", "-3", "1.5", "12abc", "abc", "10000000"] do
        params = SmtpSettings.current() |> form() |> Map.put("domain_interval_s", bad)
        assert {:error, %{"domain_interval_s" => :integer}} = SmtpSettings.save(params), bad
      end
    end

    test "addresses per session stop at 100, the most a session carries" do
      params = SmtpSettings.current() |> form() |> Map.put("rcpt_per_session", "101")
      assert {:error, %{"rcpt_per_session" => {:max, 100}}} = SmtpSettings.save(params)

      assert {:ok, _} = SmtpSettings.save(Map.put(params, "rcpt_per_session", "100"))
    end

    test "a lease below the floor is refused with the floor, the floor itself is fine" do
      floor = Config.smtp_lease_floor_s()
      params = SmtpSettings.current() |> form()

      for below <- ["1", "120", Integer.to_string(floor - 1)] do
        assert {:error, %{"smtp_lease_s" => {:min, ^floor}} = errors} =
                 SmtpSettings.save(Map.put(params, "smtp_lease_s", below))

        assert map_size(errors) == 1
      end

      assert {:ok, _} =
               SmtpSettings.save(Map.put(params, "smtp_lease_s", Integer.to_string(floor)))

      assert {:ok, _} = SmtpSettings.save(Map.put(params, "smtp_lease_s", "900"))
      assert Config.smtp_lease_s() == 900
    end

    test "a lease below the floor writes nothing, not even the other fields" do
      params =
        SmtpSettings.current()
        |> form()
        |> Map.merge(%{"smtp_lease_s" => "100", "helo" => "new.acme-mail.test"})

      assert {:error, %{"smtp_lease_s" => {:min, _}}} = SmtpSettings.save(params)
      assert Config.smtp_helo() == nil
      assert Settings.get_setting("email_verify_smtp_lease_s") == nil
    end

    test "a stored lease below the floor is shown, and kept in force, as the floor" do
      put("email_verify_smtp_lease_s", "60")

      assert SmtpSettings.current().numbers["smtp_lease_s"] == Config.smtp_lease_floor_s()
    end

    test "nothing is written when one field is wrong" do
      put("email_verify_smtp_helo", "keep.acme-mail.test")

      params =
        SmtpSettings.current()
        |> form()
        |> Map.merge(%{"helo" => "new.acme-mail.test", "smtp_lease_s" => "0"})

      assert {:error, errors} = SmtpSettings.save(params)
      assert Map.keys(errors) == ["smtp_lease_s"]
      assert Config.smtp_helo() == "keep.acme-mail.test"
    end

    test "reports every wrong field at once" do
      params =
        SmtpSettings.current()
        |> form()
        |> Map.merge(%{"mail_from" => "nope", "grey_max_attempts" => "x"})

      assert {:error, errors} = SmtpSettings.save(params)
      assert errors == %{"mail_from" => :address, "grey_max_attempts" => :integer}
    end

    test "a field missing from the params keeps its value" do
      put("email_verify_smtp_lease_s", "400")

      assert {:ok, _} = SmtpSettings.save(%{"mail_from" => "verify@acme-mail.test"})

      assert Config.smtp_lease_s() == 400
      assert Config.smtp_mail_from() == {"verify@acme-mail.test", :override}
    end

    test "non-string values are refused instead of raising" do
      assert {:error, %{"rcpt_per_session" => :integer}} =
               SmtpSettings.save(%{"rcpt_per_session" => %{"a" => 1}})

      assert {:error, %{"mail_from" => :address}} = SmtpSettings.save(%{"mail_from" => 5})
    end

    test "writes only what differs from the value in force" do
      params = SmtpSettings.current() |> form() |> Map.put("rcpt_per_session", "20")

      assert {:ok, _} = SmtpSettings.save(params)

      assert Settings.get_setting("email_verify_rcpt_per_session") == "20"
      assert Settings.get_setting("email_verify_domain_interval_s") == nil
      assert Settings.get_setting("email_verify_smtp_helo") == nil
    end

    test "a number changed back to its default is not stored again" do
      put("email_verify_domain_pause_min", "15")
      params = SmtpSettings.current() |> form() |> Map.put("domain_pause_min", "15")

      assert {:ok, _} = SmtpSettings.save(params)
      assert Settings.get_setting("email_verify_domain_pause_min") == "15"
    end

    test "does not touch the mode" do
      put("email_verify_smtp_mode", "local")
      assert {:ok, _} = SmtpSettings.save(SmtpSettings.current() |> form())
      assert Config.smtp_mode_setting() == "local"
      assert Settings.get_setting("email_verify_smtp_mode") == "local"
    end
  end

  # What the form posts: every text and every number as a string.
  defp form(current) do
    %{
      "mail_from" => current.mail_from,
      "helo" => current.helo,
      "selftest_host" => current.selftest_host
    }
    |> Map.merge(Map.new(current.numbers, fn {field, value} -> {field, to_string(value)} end))
  end
end
