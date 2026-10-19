defmodule PhoenixKit.Modules.Emails.Verification.DictionariesTest do
  # persistent_term and the app env are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Emails.Verification.Dictionaries

  setup do
    Dictionaries.reload()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_emails, :verification_lists_dir)
      Dictionaries.reload()
    end)
  end

  describe "the shipped lists" do
    test "are non-trivial" do
      assert Dictionaries.size(:disposable) > 1_000
      assert Dictionaries.size(:tlds) > 1_000
      assert Dictionaries.size(:free) > 50
      assert Dictionaries.size(:role_prefixes) > 20
      assert Dictionaries.size(:not_fake) == 0
    end

    test "valid_tld?/1" do
      assert Dictionaries.valid_tld?("com")
      assert Dictionaries.valid_tld?("EE")
      assert Dictionaries.valid_tld?("xn--p1ai")
      refute Dictionaries.valid_tld?("invalidtld")
      refute Dictionaries.valid_tld?("")
    end

    test "disposable?/1 covers the listed domain and its subdomains" do
      assert Dictionaries.disposable?("mailinator.com")
      assert Dictionaries.disposable?("MAILINATOR.com")
      assert Dictionaries.disposable?("a.b.mailinator.com")
      refute Dictionaries.disposable?("example.com")
      refute Dictionaries.disposable?("mailinator.com.example.org")
    end

    test "free?/1 knows exact domains and name.* patterns" do
      for free <- [
            "gmail.com",
            "outlook.com",
            "mail.ru",
            "web.de",
            "seznam.cz",
            "abv.bg",
            "yahoo.com",
            "yahoo.co.uk",
            "yahoo.de",
            "gmx.net",
            "GMX.at"
          ] do
        assert Dictionaries.free?(free), "#{free} should be free"
      end

      for not_free <- [
            "hydroforce.ee",
            "example.com",
            "yahoo.evil.example.com",
            "yahoo.evil.com",
            "mygmail.com",
            "sub.gmail.com",
            "yahoo.invalidtld"
          ] do
        refute Dictionaries.free?(not_free), "#{not_free} should not be free"
      end
    end

    test "role?/1 ignores case and a +tag" do
      assert Dictionaries.role?("info")
      assert Dictionaries.role?("Sales")
      assert Dictionaries.role?("support+billing")
      refute Dictionaries.role?("john")
      refute Dictionaries.role?("info.john")
    end
  end

  describe "an external lists directory" do
    @describetag :tmp_dir

    test "is merged on top of the shipped lists, never replacing them", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "disposable.txt"), "# private\nPrivate-Throwaway.example\n\n")
      File.write!(Path.join(dir, "free.txt"), "myfreemail.test\n")
      File.write!(Path.join(dir, "role_prefixes.txt"), "kitchen\n")
      File.write!(Path.join(dir, "tlds.txt"), "internal\n")
      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)
      Dictionaries.reload()

      assert Dictionaries.disposable?("private-throwaway.example")
      assert Dictionaries.disposable?("mailinator.com")
      assert Dictionaries.free?("myfreemail.test")
      assert Dictionaries.free?("gmail.com")
      assert Dictionaries.role?("kitchen")
      assert Dictionaries.role?("info")
      assert Dictionaries.valid_tld?("internal")
      assert Dictionaries.valid_tld?("com")
    end

    test "not_fake.txt whitelists a disposable domain", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "not_fake.txt"), "mailinator.com\n")
      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)
      Dictionaries.reload()

      refute Dictionaries.disposable?("mailinator.com")
      refute Dictionaries.disposable?("x.mailinator.com")
      assert Dictionaries.disposable?("guerrillamail.com")
    end

    test "a missing directory is skipped, with a warning", %{tmp_dir: dir} do
      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, Path.join(dir, "nope"))

      log =
        capture_log(fn ->
          Dictionaries.reload()
          assert Dictionaries.disposable?("mailinator.com")
        end)

      assert log =~ "does not exist"
      assert log =~ "NOT applied"
    end

    test "a file missing from an existing directory is skipped quietly", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "role_prefixes.txt"), "kitchen\n")
      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)

      log =
        capture_log(fn ->
          Dictionaries.reload()
          assert Dictionaries.role?("kitchen")
          assert Dictionaries.disposable?("mailinator.com")
        end)

      refute log =~ "Email verification"
    end

    test "a file that exists but cannot be read is skipped, with a warning", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "disposable.txt"))
      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)

      log =
        capture_log(fn ->
          Dictionaries.reload()
          assert Dictionaries.disposable?("mailinator.com")
        end)

      assert log =~ "cannot read"
    end
  end

  test "reload/0 makes the next lookup read the files again", %{} do
    assert Dictionaries.valid_tld?("com")
    :ok = Dictionaries.reload()
    assert Dictionaries.valid_tld?("com")
  end
end
