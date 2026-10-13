defmodule PhoenixKit.Modules.Emails.TableColumnsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.TableColumns

  describe "reorder_columns/2" do
    test "moves a column between valid indices" do
      assert TableColumns.reorder_columns(["to", "subject", "status"], %{
               "from" => "0",
               "to" => "2"
             }) ==
               ["subject", "status", "to"]
    end

    test "accepts indices that arrive as integers" do
      assert TableColumns.reorder_columns(["to", "subject", "status"], %{"from" => 0, "to" => 2}) ==
               ["subject", "status", "to"]
    end

    test "a non-numeric index leaves the columns unchanged instead of raising" do
      columns = ["to", "subject", "status"]

      for {from, to} <- [{"abc", "1"}, {"0", ""}, {"1.5", "0"}, {"-1", "0"}, {nil, "0"}] do
        assert TableColumns.reorder_columns(columns, %{"from" => from, "to" => to}) == columns
      end
    end
  end
end
