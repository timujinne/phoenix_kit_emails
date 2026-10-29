defmodule PhoenixKit.Modules.Emails.TemplateTest do
  @moduledoc """
  What is left of the retired database template row: the pieces
  `PhoenixKit.Modules.Emails.TemplateExport` reads stored rows with.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Template

  describe "raw_html_variables/0" do
    test "lists billing's two ready-made HTML variables and nothing else" do
      assert Template.raw_html_variables() == ["line_items_html", "line_items_table_html"]
    end
  end

  describe "get_translation/3" do
    test "exact locale, then base language, then the default, then any value" do
      map = %{"en" => "Hello", "uk" => "Привіт", "de" => "Hallo"}

      assert Template.get_translation(map, "uk") == "Привіт"
      assert Template.get_translation(map, "de-AT") == "Hallo"
      assert Template.get_translation(map, "fr") == "Hello"
      assert Template.get_translation(%{"de" => "Hallo"}, "fr") == "Hallo"
    end

    test "nil, an empty map and a non-map are the empty string" do
      assert Template.get_translation(nil, "en") == ""
      assert Template.get_translation(%{}, "en") == ""
      assert Template.get_translation("plain", "en") == ""
    end
  end

  describe "placeholder_regex/0" do
    test "tells the escaped form from the raw one and ignores everything else" do
      scan = fn text ->
        Regex.scan(Template.placeholder_regex(), text, capture: :all_names)
      end

      # captures come back by name: [double, triple]
      assert [["user_name", ""]] = scan.("Hi {{ user_name }}")
      assert [["", "line_items_html"]] = scan.("{{{line_items_html}}}")
      assert [] = scan.("{{user.name}} {{a-b}} {{x")
    end
  end
end
