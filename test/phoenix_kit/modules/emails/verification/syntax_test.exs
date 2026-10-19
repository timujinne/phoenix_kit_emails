defmodule PhoenixKit.Modules.Emails.Verification.SyntaxTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Syntax

  defp check(address) do
    [local, domain] = String.split(address, "@", parts: 2)
    Syntax.check(local, domain)
  end

  test "accepts ordinary addresses" do
    for ok <- [
          "john@example.com",
          "john.doe+tag@sub.example.co.uk",
          "o'brien@example.com",
          "a_b-c@example.com",
          "1@example.com",
          "x@xn--bcher-kva.example",
          "!#$%&'*+/=?^_`{|}~-@example.com"
        ] do
      assert check(ok) == :ok, "rejected #{ok}"
    end
  end

  test "dots in the local part" do
    assert {:error, :local_dots} = check(".a@example.com")
    assert {:error, :local_dots} = check("a.@example.com")
    assert {:error, :local_dots} = check("a..b@example.com")
  end

  test "characters outside the dot-atom set" do
    for bad <- [
          "a b@example.com",
          "a(b@example.com",
          "a,b@example.com",
          "\"a\"@example.com",
          "é@example.com",
          "a<b@example.com"
        ] do
      assert {:error, :local_chars} = check(bad), "accepted #{inspect(bad)}"
    end
  end

  test "length limits: 64 local, 63 per label, 254 overall" do
    assert check(String.duplicate("a", 64) <> "@example.com") == :ok
    assert {:error, :local_too_long} = check(String.duplicate("a", 65) <> "@example.com")

    assert check("a@" <> String.duplicate("b", 63) <> ".com") == :ok
    assert {:error, :domain_label_too_long} = check("a@" <> String.duplicate("b", 64) <> ".com")

    long_domain = Enum.map_join(1..4, ".", fn _ -> String.duplicate("d", 60) end) <> ".com"
    assert {:error, :too_long} = check(String.duplicate("a", 60) <> "@" <> long_domain)
  end

  test "the domain needs at least two labels" do
    assert {:error, :domain_no_dot} = check("a@localhost")
  end

  test "empty labels, stray hyphens and other characters in the domain" do
    assert {:error, :domain_dots} = check("a@.example.com")
    assert {:error, :domain_dots} = check("a@example..com")
    assert {:error, :domain_dots} = check("a@example.com.")
    assert {:error, :domain_chars} = check("a@-example.com")
    assert {:error, :domain_chars} = check("a@example-.com")
    assert {:error, :domain_chars} = check("a@exa_mple.com")
    assert {:error, :domain_chars} = check("a@exa mple.com")
    assert {:error, :domain_chars} = check("a@[127.0.0.1]")
  end
end
