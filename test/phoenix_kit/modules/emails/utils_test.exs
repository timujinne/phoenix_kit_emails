defmodule PhoenixKit.Modules.Emails.UtilsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Utils

  doctest Utils, only: [parse_int: 3, parse_page: 1, clamp_page: 2]

  describe "parse_int/3" do
    test "a well-formed integer string is returned as is" do
      assert Utils.parse_int("3", 1) == 3
      assert Utils.parse_int(" 42 ", 1) == 42
    end

    test "an integer passes through — LiveView event payloads arrive typed" do
      assert Utils.parse_int(7, 1) == 7
    end

    test "anything that is not a whole integer falls back to the default" do
      for value <- ["abc", "", "   ", "2abc", "1.5", "1e3", "--1", nil, 1.5, %{}, ["1"]] do
        assert Utils.parse_int(value, 25) == 25, "expected default for #{inspect(value)}"
      end
    end

    test "a value below :min falls back to the default" do
      assert Utils.parse_int("0", 1, min: 1) == 1
      assert Utils.parse_int("-1", 1, min: 1) == 1
      assert Utils.parse_int(-5, 25, min: 1) == 25
      assert Utils.parse_int("0", 7, min: 0) == 0
    end

    test "a value above :max falls back to the default" do
      assert Utils.parse_int("101", 25, min: 1, max: 100) == 25
      assert Utils.parse_int(String.duplicate("9", 40), 1, min: 1, max: 1_000_000) == 1
      assert Utils.parse_int("100", 25, min: 1, max: 100) == 100
    end

    test "above_max: :clamp turns a value above :max into :max" do
      assert Utils.parse_int("101", 25, min: 1, max: 100, above_max: :clamp) == 100
      assert Utils.parse_int("0", 25, min: 1, max: 100, above_max: :clamp) == 25
    end

    test "nil is a valid default, telling junk apart from any number" do
      assert Utils.parse_int(nil, nil) == nil
      assert Utils.parse_int("400", nil, min: 1, max: 365) == nil
      assert Utils.parse_int(42, nil, min: 1, max: 365) == 42
    end

    test "clamp_page/2 pulls a page into 1..total_pages" do
      assert Utils.clamp_page(5, 2) == 2
      assert Utils.clamp_page(0, 2) == 1
      assert Utils.clamp_page(1, 0) == 1
    end

    test "without bounds any integer is accepted" do
      assert Utils.parse_int("-3", 1) == -3
      assert Utils.parse_int("0", 1) == 0
    end
  end
end
