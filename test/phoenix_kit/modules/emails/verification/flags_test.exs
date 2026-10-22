defmodule PhoenixKit.Modules.Emails.Verification.FlagsTest do
  # The word lists live in :persistent_term and the app env: global state.
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Emails.Verification.Dictionaries
  alias PhoenixKit.Modules.Emails.Verification.Flags

  setup do
    Dictionaries.reload()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_emails, :verification_lists_dir)
      Dictionaries.reload()
    end)
  end

  defp fake?(address) do
    [local, domain] = String.split(address, "@")
    Flags.fake?(local, domain)
  end

  defp curse?(address) do
    [local, domain] = String.split(address, "@")
    Flags.curse?(local, domain)
  end

  defp use_lists(dir, files) do
    for {name, lines} <- files, do: File.write!(Path.join(dir, name), Enum.join(lines, "\r\n"))
    Application.put_env(:phoenix_kit_emails, :verification_lists_dir, dir)
    Dictionaries.reload()
  end

  describe "the fake-pattern heuristic (no lists needed)" do
    test "flags a throw-away local part" do
      for address <- [
            "12345@good-fixture.org",
            "aaaa@good-fixture.org",
            "aaab@good-fixture.org",
            "asdfgh@good-fixture.org",
            "ghjkl@good-fixture.org",
            "qwerty@good-fixture.org",
            "bcdfghjk@good-fixture.org",
            "bcdfghj@good-fixture.org",
            "bcd.fgh.jk@good-fixture.org",
            "bc.df.gh@good-fixture.org",
            "a.b.c.d.e@good-fixture.org",
            "john.paul.george.ringo.yoko@good-fixture.org",
            "qrstvwxzbcdfgh.john@good-fixture.org"
          ] do
        assert fake?(address), "#{address} should look fake"
      end
    end

    test "flags a throw-away second-level label of the domain" do
      assert fake?("john@12345.dk")
      assert fake?("john@bbbb.dk")
      assert fake?("john@bcdfghj.dk")
      assert fake?("john@mail.bcdfghj.co.uk")
    end

    test "short consonant-only names are initials, not throw-aways" do
      for address <- [
            "aha@hjj.dk",
            "skf.cz@good-fixture.org",
            "hjj@good-fixture.org",
            "bbc@good-fixture.org",
            "xkcd@good-fixture.org",
            "bcdklm@good-fixture.org",
            "bc.df@good-fixture.org",
            "john@hjj.dk",
            "john@skf.cz",
            "john@bbc.co.uk",
            "john@mail.hjj.co.uk"
          ] do
        refute fake?(address), "#{address} should not look fake"
      end
    end

    test "nine non-vowels in a row are fake even with vowels around them" do
      assert fake?("qrstvwxzb.john@good-fixture.org")
      refute fake?("qrstvwx.john@good-fixture.org")
    end

    test "leaves ordinary addresses alone" do
      for address <- [
            "john.smith@good-fixture.org",
            "info@good-fixture.org",
            "maria_k@gmail.com",
            "j.r.tolkien@good-fixture.org",
            "john.paul.george@good-fixture.org",
            "user2024@good-fixture.org",
            "ab@good-fixture.org",
            "john@bk.ru",
            "john@wp.pl",
            "john@mail.good-fixture.co.uk"
          ] do
        refute fake?(address), "#{address} should not look fake"
      end
    end

    test "a Dr./Jr./Sr. prefix does not count towards the initials rule" do
      refute fake?("dr.a.b.c.dee@good-fixture.org")
      refute fake?("jr.a.b.c.dee@good-fixture.org")
      refute fake?("sr.a.b.c.dee@good-fixture.org")
      assert fake?("x.a.b.c.dee@good-fixture.org")
      assert fake?("dr.a.b.c.d.dee@good-fixture.org")
    end

    test "four dots make an address fake whatever stands between them" do
      assert fake?("a.b.c.d.e@good-fixture.org")
      assert fake?("a1.b2.c3.d4.e5@good-fixture.org")
      refute fake?("a.b.c.dee@good-fixture.org")
    end

    test "is case-insensitive" do
      assert fake?("ASDFGH@Good-Fixture.org")
      refute fake?("John.Smith@Good-Fixture.org")
    end
  end

  describe "with lists" do
    @describetag :tmp_dir

    test "FakeAddresses entries match a domain, a local part or a whole address", %{tmp_dir: dir} do
      use_lists(dir, %{
        "FakeAddresses_Sorted.txt" => ["@fixture-fake.example", "nobodyhome@", "x@y.example"]
      })

      assert fake?("john@fixture-fake.example")
      assert fake?("NobodyHome@good-fixture.org")
      assert fake?("x@y.example")
      refute fake?("x@z.example")
      refute fake?("nobodyhomes@good-fixture.org")
      refute fake?("john@sub.fixture-fake.example")
    end

    test "a not_fake domain is never flagged fake", %{tmp_dir: dir} do
      use_lists(dir, %{
        "not_fake.txt" => ["hjj.dk", "fixture-fake.example"],
        "FakeAddresses_Sorted.txt" => ["@fixture-fake.example"]
      })

      refute fake?("aha@hjj.dk")
      refute fake?("asdfgh@x.hjj.dk")
      refute fake?("john@fixture-fake.example")
      assert fake?("asdfgh@good-fixture.org")
    end

    test "the second-level label of a free provider is not judged", %{tmp_dir: dir} do
      use_lists(dir, %{"free.txt" => ["fff.example"]})

      refute fake?("john@fff.example")
      assert fake?("john@ggg.example")
      assert fake?("asdfgh@fff.example")
    end

    test "curse words match whole words of the address, not substrings", %{tmp_dir: dir} do
      use_lists(dir, %{"CurseWords_Sorted.txt" => ["blorp", "rude word"]})

      for address <- [
            "blorp@good-fixture.org",
            "john.blorp@good-fixture.org",
            "blorp123@good-fixture.org",
            "BLORP_x@good-fixture.org",
            "john@blorp.example",
            "rude.word@good-fixture.org",
            "rude_word@good-fixture.org"
          ] do
        assert curse?(address), "#{address} should match"
      end

      for address <- [
            "blorpy@good-fixture.org",
            "reblorp@good-fixture.org",
            "rudeword@good-fixture.org",
            "rude@good-fixture.org",
            "john@good-fixture.org"
          ] do
        refute curse?(address), "#{address} should not match"
      end
    end

    test "typos match the exact domain, case-insensitively", %{tmp_dir: dir} do
      use_lists(dir, %{"Typos_Sorted.txt" => ["@gmai.example", "@gmial.example"]})

      assert Flags.typo?("john", "gmai.example")
      assert Flags.typo?("john", "GMIAL.example")
      refute Flags.typo?("john", "gmail.example")
      refute Flags.typo?("john", "x.gmai.example")
    end

    test "compute/2 returns all three flags", %{tmp_dir: dir} do
      use_lists(dir, %{
        "Typos_Sorted.txt" => ["@gmai.example"],
        "CurseWords_Sorted.txt" => ["blorp"]
      })

      assert Flags.compute("blorp", "gmai.example") == %{fake: false, curse: true, typo: true}

      assert Flags.compute("asdfgh", "good-fixture.org") == %{
               fake: true,
               curse: false,
               typo: false
             }

      assert Flags.compute("john", "good-fixture.org") == %{
               fake: false,
               curse: false,
               typo: false
             }
    end
  end

  test "with the lists shipped empty, nothing list-based is flagged" do
    refute Flags.typo?("john", "gmai.com")
    refute Flags.curse?("blorp", "good-fixture.org")
  end
end
