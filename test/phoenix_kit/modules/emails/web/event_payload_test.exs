defmodule PhoenixKit.Modules.Emails.Web.EventPayloadTest do
  @moduledoc """
  A LiveView event payload is whatever the client sends, and a crafted event
  can put an integer, `nil`, a map or a list where the template would put a
  string, send a string where it expects a map, or leave a key out. These
  handlers used to pass the value straight to `String.*`,
  `Date.from_iso8601/1`, `URI.encode_query/1`, string interpolation or
  `String.to_atom/1`, so the wrong shape raised and took the LiveView down —
  and `String.to_atom/1` grew the atom table with every new value.

  Each test sends the crafted event and then RENDERS the page from the
  resulting assigns: a handler that survives but stores the raw value in a
  form assign only moves the crash into the template (`Phoenix.HTML.Safe` is
  not implemented for maps), and a handler-only assertion stays green on it.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.RateLimiter
  alias PhoenixKit.Modules.Emails.Web.Blocklist
  alias PhoenixKit.Modules.Emails.Web.Details
  alias PhoenixKit.Modules.Emails.Web.Emails, as: EmailsLive
  alias PhoenixKit.Modules.Emails.Web.Metrics
  alias PhoenixKit.Modules.Emails.Web.Queue
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs
  alias PhoenixKit.Modules.Emails.Web.SettingsSections.EmailTracking

  @non_strings [42, nil, %{"a" => "b"}, ["x"]]
  @crafted [42, %{"a" => "b"}, ["x"]]

  setup do
    {:ok, _} = Emails.enable_system()
    :ok
  end

  ## --- Helpers ---

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  # Renders `module` from the socket's assigns, the way LiveView would after
  # the event. `:myself` is only read by LiveComponents.
  defp render!(module, socket) do
    assigns =
      socket.assigns
      |> Map.delete(:__changed__)
      |> Map.put_new(:myself, %Phoenix.LiveComponent.CID{cid: 1})

    html =
      render_component(&module.render/1, assigns, endpoint: PhoenixKitEmails.Test.StubEndpoint)

    assert is_binary(html)
    html
  end

  defp event!(module, socket, event, params) do
    assert {:noreply, socket} = module.handle_event(event, params, socket)
    socket
  end

  defp patched_to(socket) do
    case socket.redirected do
      {:live, :patch, %{to: to}} -> to
      _ -> nil
    end
  end

  defp metrics_socket do
    {:ok, socket} = Metrics.mount(%{}, %{}, bare_socket())
    socket
  end

  defp emails_socket do
    {:ok, socket} = EmailsLive.mount(%{}, %{}, bare_socket())
    {:noreply, socket} = EmailsLive.handle_params(%{}, "http://localhost/admin/emails", socket)

    socket
    |> Phoenix.Component.assign(:show_test_email_modal, true)
    |> Phoenix.Component.assign(:show_column_modal, true)
    |> Phoenix.Component.assign(:temp_selected_columns, ["to", "actions"])
  end

  # What UrlState's on_mount hook leaves behind, then the list load it
  # triggers — enough to render the page and push URL state.
  defp blocklist_socket do
    {:ok, socket} =
      Blocklist.mount(
        %{},
        %{},
        bare_socket(%{
          __phoenix_kit_url_cfg__: Blocklist.__phoenix_kit_url_state__(),
          __phoenix_kit_url_path__: "/admin/emails/blocklist",
          search_term: "",
          reason_filter: "",
          status_filter: "all",
          sort_by: :inserted_at,
          sort_dir: :desc,
          page: 1
        })
      )

    %{}
    |> Blocklist.handle_url_state(socket)
    |> Phoenix.Component.assign(:show_add_form, true)
    |> Phoenix.Component.assign(:show_import_form, true)
  end

  defp tracking_section_socket do
    {:ok, socket} = EmailTracking.update(%{id: "email-tracking"}, bare_socket())
    socket
  end

  ## --- Metrics ---

  describe "Metrics change_period" do
    test "a listed period is applied" do
      socket = event!(Metrics, metrics_socket(), "change_period", %{"period" => "last_30_days"})

      assert socket.assigns.period == :last_30_days
      render!(Metrics, socket)
    end

    test "an unknown period keeps the current one and creates no atom" do
      name = "no_such_period_#{System.unique_integer([:positive])}"

      socket = event!(Metrics, metrics_socket(), "change_period", %{"period" => name})

      assert socket.assigns.period == :last_7_days
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      render!(Metrics, socket)
    end

    test "\"custom\" is not a period this event can pick" do
      socket = event!(Metrics, metrics_socket(), "change_period", %{"period" => "custom"})

      assert socket.assigns.period == :last_7_days
      render!(Metrics, socket)
    end

    for value <- @non_strings do
      test "a #{inspect(value)} period keeps the current one" do
        socket =
          event!(Metrics, metrics_socket(), "change_period", %{
            "period" => unquote(Macro.escape(value))
          })

        assert socket.assigns.period == :last_7_days
        render!(Metrics, socket)
      end
    end

    test "a missing period keeps the current one" do
      socket = event!(Metrics, metrics_socket(), "change_period", %{})

      assert socket.assigns.period == :last_7_days
    end
  end

  describe "Metrics apply_custom_range" do
    for params <- [
          %{"start_date" => 20_260_101, "end_date" => nil},
          %{"start_date" => %{"a" => "b"}, "end_date" => ["x"]},
          %{"start_date" => "2026-10-01"},
          %{}
        ] do
      test "#{inspect(params)} is refused with a flash" do
        socket =
          event!(Metrics, metrics_socket(), "apply_custom_range", unquote(Macro.escape(params)))

        assert socket.assigns.flash["error"]
        assert socket.assigns.period == :last_7_days
        render!(Metrics, socket)
      end
    end

    # The working path, not a crafted one: `and` on the start_date assign (a
    # Date, not a boolean) raised BadBooleanError, so every custom range
    # crashed the dashboard.
    test "a valid range is applied and the metrics render for it" do
      socket =
        event!(Metrics, metrics_socket(), "apply_custom_range", %{
          "start_date" => "2026-10-01",
          "end_date" => "2026-10-07"
        })

      assert socket.assigns.period == :custom
      assert socket.assigns.start_date == ~D[2026-10-01]
      assert socket.assigns.end_date == ~D[2026-10-07]
      refute socket.assigns.flash["error"]
      render!(Metrics, socket)
    end
  end

  ## --- Settings sections ---

  describe "S3 settings" do
    for value <- @crafted do
      test "a #{inspect(value)} bucket is refused and the stored one kept" do
        {:ok, _} = Emails.set_s3_bucket("kept-bucket")

        socket =
          event!(EmailTracking, tracking_section_socket(), "update_s3_bucket", %{
            "value" => unquote(Macro.escape(value))
          })

        assert socket.assigns.flash["error"]
        assert socket.assigns.email_s3_bucket == "kept-bucket"
        assert Emails.get_s3_bucket() == "kept-bucket"
        render!(EmailTracking, socket)
      end

      test "a #{inspect(value)} connection is refused and the stored one kept" do
        {:ok, _} = Emails.set_s3_integration("kept-uuid")

        socket =
          event!(EmailTracking, tracking_section_socket(), "update_s3_integration", %{
            "value" => unquote(Macro.escape(value))
          })

        assert socket.assigns.flash["error"]
        assert socket.assigns.email_s3_integration == "kept-uuid"
        assert Emails.get_s3_integration() == "kept-uuid"
        render!(EmailTracking, socket)
      end
    end
  end

  describe "SES per-account tracking settings" do
    for value <- ["x", 42, ["a"]] do
      test "tracking=#{inspect(value)} for a known connection is refused with a flash" do
        {:ok, %{uuid: uuid} = connection} = Integrations.add_connection("aws_ses", "payload")

        socket = bare_socket(%{aws_ses_connections: [connection]})

        socket =
          event!(AmazonSesSqs, socket, "save_tracking_account", %{
            "uuid" => uuid,
            "tracking" => unquote(Macro.escape(value))
          })

        assert socket.assigns.flash["error"]
      end
    end
  end

  ## --- Blocklist ---

  describe "Blocklist add_block" do
    test "a non-string email is refused with a flash and nothing is blocked" do
      socket =
        event!(Blocklist, blocklist_socket(), "add_block", %{
          "email" => 42,
          "reason" => "manual",
          "expires_at" => ""
        })

      assert socket.assigns.flash["error"]
      assert RateLimiter.list_blocklist(%{}) == []
      render!(Blocklist, socket)
    end

    for expires_at <- [20_260_101, %{"a" => "b"}, ["2026-12-31"]] do
      test "a #{inspect(expires_at)} expiry is ignored and the address blocked without one" do
        email = "payload-#{System.unique_integer([:positive])}@example.com"

        socket =
          event!(Blocklist, blocklist_socket(), "add_block", %{
            "email" => email,
            "reason" => "manual",
            "expires_at" => unquote(Macro.escape(expires_at))
          })

        assert [%{email: ^email, expires_at: nil}] = RateLimiter.list_blocklist(%{})
        render!(Blocklist, socket)
      end
    end

    for params <- [%{"email" => "a@example.com"}, %{"reason" => "manual"}, %{}] do
      test "a payload missing keys (#{inspect(params)}) does not raise" do
        socket = event!(Blocklist, blocklist_socket(), "add_block", unquote(Macro.escape(params)))

        render!(Blocklist, socket)
      end
    end

    # Already safe — import_blocklist_csv/1 rescues — but pinned with the rest.
    test "a non-string CSV import is refused with a flash" do
      socket = event!(Blocklist, blocklist_socket(), "import_csv", %{"csv_content" => 42})

      assert socket.assigns.flash["error"]
      refute socket.assigns.flash["info"]
      render!(Blocklist, socket)
    end
  end

  describe "Blocklist remove and selection" do
    for email <- @crafted do
      test "remove_block with #{inspect(email)} does nothing" do
        socket =
          event!(Blocklist, blocklist_socket(), "remove_block", %{
            "email" => unquote(Macro.escape(email))
          })

        refute socket.assigns.flash["info"]
        render!(Blocklist, socket)
      end

      test "toggle_email_selection with #{inspect(email)} leaves the selection alone" do
        socket =
          event!(Blocklist, blocklist_socket(), "toggle_email_selection", %{
            "email" => unquote(Macro.escape(email))
          })

        assert socket.assigns.selected_emails == []

        # ...so a bulk remove after it has nothing crafted to pass on.
        socket =
          socket
          |> Phoenix.Component.assign(:bulk_action, "remove")
          |> then(&event!(Blocklist, &1, "execute_bulk_action", %{}))

        render!(Blocklist, socket)
      end
    end
  end

  describe "Blocklist filters" do
    for {event, key} <- [
          {"filter_search", "search"},
          {"filter_reason", "reason"},
          {"filter_status", "status"}
        ],
        value <- @crafted do
      test "#{event} with #{inspect(value)} keeps the current filter" do
        socket =
          event!(Blocklist, blocklist_socket(), unquote(event), %{
            unquote(key) => unquote(Macro.escape(value))
          })

        assert patched_to(socket) == nil
        render!(Blocklist, socket)
      end
    end
  end

  ## --- Emails list ---

  describe "Emails list" do
    test "a non-string search query is dropped, not trimmed" do
      socket = event!(EmailsLive, emails_socket(), "filter", %{"search" => %{"query" => 42}})

      refute patched_to(socket) =~ "search="
      render!(EmailsLive, socket)
    end

    for event <- ["validate_test_email", "send_test_email"],
        recipient <- @non_strings do
      test "#{event} with recipient #{inspect(recipient)} is a validation error" do
        socket =
          event!(EmailsLive, emails_socket(), unquote(event), %{
            "test_email" => %{"recipient" => unquote(Macro.escape(recipient))}
          })

        assert socket.assigns.test_email_form.errors.recipient
        refute_received {:send_test_email, _, _}
        render!(EmailsLive, socket)
      end
    end

    for event <- ["validate_test_email", "send_test_email"],
        params <- [%{"test_email" => "x"}, %{"test_email" => 42}, %{}] do
      test "#{event} with #{inspect(params)} is a validation error" do
        socket =
          event!(EmailsLive, emails_socket(), unquote(event), unquote(Macro.escape(params)))

        assert socket.assigns.test_email_form.errors.recipient
        refute_received {:send_test_email, _, _}
        render!(EmailsLive, socket)
      end
    end

    test "a non-string column order keeps the working copy" do
      socket =
        emails_socket()
        |> Phoenix.Component.assign(:temp_selected_columns, ["to", "status", "actions"])
        |> then(&event!(EmailsLive, &1, "update_table_columns", %{"column_order" => 42}))

      assert socket.assigns.selected_columns == ["to", "status", "actions"]
      render!(EmailsLive, socket)
    end

    for uuid <- @crafted do
      test "view_details with #{inspect(uuid)} stays on the page" do
        socket =
          event!(EmailsLive, emails_socket(), "view_details", %{
            "uuid" => unquote(Macro.escape(uuid))
          })

        assert socket.redirected == nil
      end
    end
  end

  describe "Emails list reorder_selected_columns" do
    for ids <- [42, "to,status", %{"0" => "to"}, [1, 2], ["to", nil]] do
      test "ordered_ids=#{inspect(ids)} leaves the working copy alone" do
        socket =
          event!(EmailsLive, emails_socket(), "reorder_selected_columns", %{
            "ordered_ids" => unquote(Macro.escape(ids))
          })

        assert socket.assigns.temp_selected_columns == ["to", "actions"]
        render!(EmailsLive, socket)
      end
    end

    test "a list of ids is still applied" do
      socket =
        event!(EmailsLive, emails_socket(), "reorder_selected_columns", %{
          "ordered_ids" => ["status", "to"]
        })

      assert socket.assigns.temp_selected_columns == ["status", "to", "actions"]
      render!(EmailsLive, socket)
    end
  end

  ## --- Lists ---

  describe "Emails list filter payloads that are not flat strings" do
    for {live, socket_fun} <- [{EmailsLive, :emails_socket}] do
      test "#{inspect(live)}: a nested filter value is dropped, the rest kept" do
        socket =
          event!(unquote(live), unquote(socket_fun)(), "filter", %{
            "filter" => %{
              "status" => %{"a" => "b"},
              "category" => ["x"],
              "search" => 5,
              "is_system" => "true"
            }
          })

        to = patched_to(socket)
        assert to =~ "is_system=true"
        refute to =~ "status="
        refute to =~ "category="
        render!(unquote(live), socket)
      end

      for params <- [
            %{"field" => %{"a" => "b"}, "value" => "sent"},
            %{"field" => "status", "value" => %{"a" => "b"}},
            %{"field" => "status", "value" => ["x"]},
            %{"field" => 42, "value" => 42}
          ] do
        test "#{inspect(live)}: set_filter #{inspect(params)} keeps the current filters" do
          socket =
            event!(
              unquote(live),
              unquote(socket_fun)(),
              "set_filter",
              unquote(Macro.escape(params))
            )

          assert patched_to(socket) == nil
          render!(unquote(live), socket)
        end
      end

      test "#{inspect(live)}: set_filter with strings still patches" do
        socket =
          event!(unquote(live), unquote(socket_fun)(), "set_filter", %{
            "field" => "status",
            "value" => "active"
          })

        assert patched_to(socket) =~ "status=active"
      end
    end
  end

  describe "Queue selection" do
    defp queue_socket do
      {:ok, socket} = Queue.mount(%{}, %{}, bare_socket())
      socket
    end

    for uuid <- @crafted do
      test "toggle_email_selection with #{inspect(uuid)} leaves the selection alone" do
        socket =
          event!(Queue, queue_socket(), "toggle_email_selection", %{
            "email_uuid" => unquote(Macro.escape(uuid))
          })

        assert socket.assigns.selected_emails == []

        socket =
          socket
          |> Phoenix.Component.assign(:bulk_action, "delete")
          |> then(&event!(Queue, &1, "execute_bulk_action", %{}))

        render!(Queue, socket)
      end

      test "retry_email with #{inspect(uuid)} is refused with a flash" do
        socket =
          event!(Queue, queue_socket(), "retry_email", %{
            "email_uuid" => unquote(Macro.escape(uuid))
          })

        assert socket.assigns.flash["error"]
        render!(Queue, socket)
      end
    end
  end

  ## --- Navigation events that interpolate the payload into a path ---

  describe "navigation events" do
    for value <- @crafted do
      test "Queue view_details with #{inspect(value)} stays on the page" do
        socket =
          event!(Queue, bare_socket(), "view_details", %{"uuid" => unquote(Macro.escape(value))})

        assert socket.redirected == nil
      end

      test "Details view_related campaign_id=#{inspect(value)} stays on the page" do
        socket =
          event!(Details, bare_socket(), "view_related", %{
            "campaign_id" => unquote(Macro.escape(value))
          })

        assert socket.redirected == nil
      end

      test "Details view_related template_name=#{inspect(value)} stays on the page" do
        socket =
          event!(Details, bare_socket(), "view_related", %{
            "template_name" => unquote(Macro.escape(value))
          })

        assert socket.redirected == nil
      end
    end

    test "Details view_related encodes the value into the query string" do
      socket =
        event!(Details, bare_socket(), "view_related", %{"campaign_id" => "spring sale&x=1"})

      assert {:live, :redirect, %{to: to}} = socket.redirected
      assert to =~ "campaign_id=spring+sale%26x%3D1"
    end
  end
end
