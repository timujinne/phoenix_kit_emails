defmodule PhoenixKit.Modules.Emails.Web.EmailsTest do
  @moduledoc """
  `?page` and `?per_page` are whatever the address bar says. They used to go
  through `String.to_integer/1`, so `/admin/emails?page=abc` (or an empty,
  fractional or huge value) raised and took the LiveView down. A bad value
  must fall back to the first page at the default size instead.

  There is no router in this package, so the page is driven the way LiveView
  drives it: mount/3, then handle_params/3, then render/1 on the result.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Web.Emails, as: EmailsLive

  setup do
    {:ok, _} = Emails.enable_system()

    for n <- 1..3 do
      {:ok, _} =
        Emails.create_log(%{
          message_id: "page-param-#{n}-#{System.unique_integer([:positive])}",
          to: "to#{n}@example.com",
          from: "from@example.com",
          subject: "Page param subject #{n}",
          provider: "aws_ses",
          status: "sent",
          sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end

    :ok
  end

  defp visit(params) do
    {:ok, socket} =
      EmailsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}}
      })

    {:noreply, socket} = EmailsLive.handle_params(params, "http://localhost/admin/emails", socket)

    html =
      render_component(&EmailsLive.render/1, Map.delete(socket.assigns, :__changed__),
        endpoint: PhoenixKitEmails.Test.StubEndpoint
      )

    {socket.assigns, html}
  end

  describe "malformed ?page" do
    for page <- ["abc", "-1", "0", "", "1.5", "2abc"] do
      test "page=#{inspect(page)} renders the first page" do
        {assigns, html} = visit(%{"page" => unquote(page)})

        assert assigns.page == 1
        assert assigns.per_page == 25
        assert length(assigns.logs) == 3
        assert html =~ "Page param subject 1"
      end
    end

    test "a page number past the 1_000_000 ceiling falls back to the first page" do
      {assigns, _html} = visit(%{"page" => String.duplicate("9", 30)})

      assert assigns.page == 1
      assert length(assigns.logs) == 3
    end

    test "a page past the end lands on the last page" do
      {assigns, _html} = visit(%{"page" => "5", "per_page" => "2"})

      assert assigns.total_pages == 2
      assert assigns.page == 2
      assert length(assigns.logs) == 1
    end
  end

  describe "malformed ?per_page" do
    for per_page <- ["abc", "", "0", "-5"] do
      test "per_page=#{inspect(per_page)} falls back to the default size" do
        {assigns, html} = visit(%{"per_page" => unquote(per_page)})

        assert assigns.page == 1
        assert assigns.per_page == 25
        assert html =~ "Page param subject 1"
      end
    end

    test "a huge per_page is capped at the maximum" do
      {assigns, _html} = visit(%{"per_page" => "100000000000000000000000"})

      assert assigns.per_page == 100
      assert length(assigns.logs) == 3
    end
  end

  test "well-formed values are still honored" do
    {assigns, _html} = visit(%{"page" => "2", "per_page" => "2"})

    assert assigns.page == 2
    assert assigns.per_page == 2
    assert length(assigns.logs) == 1
  end
end
