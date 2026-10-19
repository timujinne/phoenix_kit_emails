defmodule PhoenixKit.Modules.Emails.Verification.NormalizerTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Normalizer

  describe "normalize/1" do
    test "trims, lowercases the domain and keeps the local part as typed" do
      assert {:ok, %{email: "John.Doe@example.com", local: "John.Doe", domain: "example.com"}} =
               Normalizer.normalize("  John.Doe@EXAMPLE.Com \n")
    end

    test "converts an internationalised domain to punycode" do
      assert {:ok, %{domain: "xn--bcher-kva.example", email: "a@xn--bcher-kva.example"}} =
               Normalizer.normalize("a@Bücher.example")

      assert {:ok, %{domain: "xn--d1acpjx3f.com"}} = Normalizer.normalize("a@ЯНДЕКС.com")
    end

    test "rejects what is not a single local@domain" do
      for bad <- ["", "   ", "plain", "a@b@c.com", "@example.com", "a@", "a@@b.com"] do
        assert {:error, _} = Normalizer.normalize(bad), "accepted #{inspect(bad)}"
      end

      assert {:error, :empty} = Normalizer.normalize("  ")
      assert {:error, :not_a_string} = Normalizer.normalize(nil)
      assert {:error, :not_a_string} = Normalizer.normalize(42)
    end

    test "an unconvertible IDN is an error, not a crash" do
      assert {:error, :bad_idn} = Normalizer.normalize("a@-ü.com")
      assert {:error, :bad_idn} = Normalizer.normalize("a@xn--ü.com")
    end

    test "leaves ASCII domains alone, malformed or not - Syntax judges them" do
      assert {:ok, %{domain: "exa mple.com"}} = Normalizer.normalize("a@exa mple.com")
    end
  end

  describe "storage_key/1" do
    test "is the normalised address when there is one" do
      assert Normalizer.storage_key(" A@Example.COM ") == "A@example.com"
    end

    test "is the trimmed input when the address cannot be normalised" do
      assert Normalizer.storage_key("  not an address ") == "not an address"
    end

    test "is nil for blank or non-text input" do
      assert Normalizer.storage_key("  ") == nil
      assert Normalizer.storage_key(nil) == nil
    end

    test "is nil for input a text column cannot hold: NUL bytes and invalid UTF-8" do
      assert Normalizer.storage_key("a\0b@fixture.org") == nil
      assert Normalizer.storage_key(<<"a", 0xFF, "@fixture.org">>) == nil
      assert Normalizer.storage_key(<<0xFF, 0xFE, "xx">>) == nil
      assert Normalizer.storage_key("\0") == nil
    end

    test "storage_key/2 reuses an earlier normalisation" do
      input = " A@Example.COM "
      assert Normalizer.storage_key(input, Normalizer.normalize(input)) == "A@example.com"
      assert Normalizer.storage_key("junk", {:error, :bad_at}) == "junk"
      assert Normalizer.storage_key(<<0xFF>>, {:error, :bad_at}) == nil
    end

    test "is bounded" do
      assert String.length(Normalizer.storage_key(String.duplicate("a", 1000) <> "@x.com")) == 320
      assert String.length(Normalizer.storage_key(String.duplicate("a", 1000))) == 320
    end
  end
end
