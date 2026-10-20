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

    test "the lists for flags and SMTP phrases ship empty" do
      for name <- [:typos, :fake, :curse, :smtp_grey, :smtp_quota, :smtp_block] do
        assert Dictionaries.size(name) == 0, "#{name} should ship empty"
      end
    end

    test "the user-unknown phrases ship with twelve generic entries" do
      assert Dictionaries.size(:smtp_user_unknown) == 12

      phrases = Dictionaries.phrases(:smtp_user_unknown)
      assert "user unknown" in phrases
      assert "5.1.1" in phrases
      assert "invalid recipient" in phrases
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
            "acme-mail.test",
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

  describe "a Kellerman-style directory, as shipped by the vendor" do
    @describetag :tmp_dir

    # CRLF line endings, mixed case, a trailing space, TLDs with a leading dot:
    # the shape of the original files. Fixture content only, written here.
    setup %{tmp_dir: dir} do
      crlf = fn lines -> Enum.join(lines, "\r\n") <> "\r\n" end

      files = %{
        "DEA_Sorted.txt" => ["fixture-throwaway.example", "Other-Fixture-Dead.TEST"],
        "FreeEmail_Sorted.txt" => ["fixture-free.example"],
        "TopLevelDomains.txt" => [".fixturetld", ".xn--fixture"],
        "Typos_Sorted.txt" => ["@gmai.example", "@gmial.example"],
        "FakeAddresses_Sorted.txt" => ["@fixture-fake.example", "nobodyhome@", "x@y.example"],
        "CurseWords_Sorted.txt" => ["blorp", "rude word"],
        "Greylisting_Sorted.txt" => ["Fixture Grey Two", "fixture grey one "],
        "MailboxQuota_Sorted.txt" => ["fixture quota one"],
        "Blocking_Sorted.txt" => ["Fixture Block Two", "fixture block one"]
      }

      for {name, lines} <- files, do: File.write!(Path.join(dir, name), crlf.(lines))

      Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)
      Dictionaries.reload()
      :ok
    end

    test "disposable, free and TLD lists are read under their Kellerman names" do
      assert Dictionaries.disposable?("fixture-throwaway.example")
      assert Dictionaries.disposable?("other-fixture-dead.test")
      assert Dictionaries.free?("fixture-free.example")
      assert Dictionaries.valid_tld?("fixturetld")
      assert Dictionaries.valid_tld?("xn--fixture")
      refute Dictionaries.valid_tld?(".fixturetld")
    end

    test "CRLF leaves no stray carriage return in an entry" do
      assert Dictionaries.disposable?("fixture-throwaway.example")
      refute Dictionaries.disposable?("fixture-throwaway.example\r")
      refute Dictionaries.listed?(:fake, "nobodyhome@\r")
    end

    test "the flag lists are loaded, entries lowercased" do
      assert Dictionaries.size(:typos) == 2
      assert Dictionaries.size(:fake) == 3
      assert Dictionaries.size(:curse) == 2
      assert Dictionaries.listed?(:typos, "@gmai.example")
      assert Dictionaries.listed?(:fake, "nobodyhome@")
      assert Dictionaries.listed?(:curse, "rude word")
      assert Dictionaries.listed?(:curse, "Rude Word")
      refute Dictionaries.listed?(:curse, "rude")
    end

    test "the SMTP phrase lists are exposed, trimmed and lowercased" do
      assert Dictionaries.phrases(:smtp_grey) == ["fixture grey one", "fixture grey two"]
      assert Dictionaries.phrases(:smtp_quota) == ["fixture quota one"]
      assert Dictionaries.phrases(:smtp_block) == ["fixture block one", "fixture block two"]
    end

    test "our own file names work too, next to the Kellerman ones", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "typos.txt"), "@own-typo.example\n")
      File.write!(Path.join(dir, "disposable.txt"), "own-dead.example\n")
      File.write!(Path.join(dir, "smtp_block.txt"), "own phrase\n")
      Dictionaries.reload()

      assert Dictionaries.listed?(:typos, "@own-typo.example")
      assert Dictionaries.listed?(:typos, "@gmai.example")
      assert Dictionaries.disposable?("own-dead.example")
      assert Dictionaries.disposable?("fixture-throwaway.example")
      assert "own phrase" in Dictionaries.phrases(:smtp_block)
      assert "fixture block two" in Dictionaries.phrases(:smtp_block)
    end

    test "a leading dot and a byte-order mark are tolerated in our own file too", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "tlds.txt"), "\uFEFF.dotted\r\n.another\r\n")
      Dictionaries.reload()

      assert Dictionaries.valid_tld?("dotted")
      assert Dictionaries.valid_tld?("another")
    end
  end

  test "reload/0 makes the next lookup read the files again", %{} do
    assert Dictionaries.valid_tld?("com")
    :ok = Dictionaries.reload()
    assert Dictionaries.valid_tld?("com")
  end
end
