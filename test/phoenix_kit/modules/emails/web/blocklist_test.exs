defmodule PhoenixKit.Modules.Emails.Web.BlocklistTest do
  @moduledoc """
  `change_page` is a client event, so its payload is whatever a crafted event
  sends. `Integer.parse/1` raised on an integer or nil page; both must either
  patch to that page or be ignored.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Web.Blocklist

  # The assigns UrlState's on_mount hook leaves behind, enough for
  # push_url_state/2 to build the patch without a live connection.
  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        __phoenix_kit_url_cfg__: Blocklist.__phoenix_kit_url_state__(),
        __phoenix_kit_url_path__: "/admin/emails/blocklist",
        search_term: "",
        reason_filter: "",
        status_filter: "all",
        sort_by: :inserted_at,
        sort_dir: :desc,
        page: 1
      },
      private: %{live_temp: %{}}
    }
  end

  defp patched_to(socket) do
    case socket.redirected do
      {:live, :patch, %{to: to}} -> to
      _ -> nil
    end
  end

  test "an integer page patches to that page" do
    assert {:noreply, socket} = Blocklist.handle_event("change_page", %{"page" => 3}, socket())
    assert patched_to(socket) =~ "page=3"
  end

  test "a string page patches to that page" do
    assert {:noreply, socket} = Blocklist.handle_event("change_page", %{"page" => "2"}, socket())
    assert patched_to(socket) =~ "page=2"
  end

  for page <- [nil, "abc", "0", "-1", ""] do
    test "page=#{inspect(page)} is ignored" do
      assert {:noreply, socket} =
               Blocklist.handle_event("change_page", %{"page" => unquote(page)}, socket())

      assert patched_to(socket) == nil
    end
  end

  test "page 1, the lowest page, is accepted" do
    socket = Phoenix.Component.assign(socket(), :page, 2)

    assert {:noreply, socket} = Blocklist.handle_event("change_page", %{"page" => "1"}, socket)
    assert to = patched_to(socket)
    refute to =~ "page=2"
  end
end
