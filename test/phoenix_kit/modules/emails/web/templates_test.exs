defmodule PhoenixKit.Modules.Emails.Web.TemplatesTest do
  @moduledoc """
  Archiving a system template used to be blocked outright, while activating
  one worked silently with no confirmation — an asymmetry between "off" and
  "on". This locks in the fix: both actions are now allowed for system rows,
  but go through the confirmation modal first (reusing the same mechanism
  `request_delete` already uses), while non-system rows keep the old
  immediate behavior. Delete stays untouched and still rejected for system
  rows.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.Templates, as: TemplatesLive
  alias PhoenixKitEmails.Test.Repo

  defp bare_socket(assigns \\ %{}) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      filters: %{search: "", category: "", status: "", is_system: ""},
      page: 1,
      per_page: 25,
      sort_by: :inserted_at,
      sort_dir: :desc,
      confirmation_modal: %{show: false}
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}}
    }
  end

  # Templates.create_template/1 never honors a client-supplied is_system
  # (that's exactly what closes the reserved-name bypass — see Template
  # module docs), so a test helper that wants a genuine is_system: true row
  # has to go through the same trusted path Templates.seed_system_templates/0
  # uses: Template.changeset/3 with the literal `true`.
  defp create_system_template(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %{
      name: "sys_template_#{n}",
      slug: "sys-template-#{n}",
      display_name: %{"en" => "System Template #{n}"},
      subject: %{"en" => "Subject"},
      html_body: %{"en" => "<p>Hi</p>"},
      text_body: %{"en" => "Hi"},
      category: "system",
      status: "active"
    }

    %Template{}
    |> Template.changeset(Map.merge(base, attrs), true)
    |> Repo.insert!()
  end

  defp create_custom_template(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %{
      name: "custom_template_#{n}",
      slug: "custom-template-#{n}",
      display_name: %{"en" => "Custom Template #{n}"},
      subject: %{"en" => "Subject"},
      html_body: %{"en" => "<p>Hi</p>"},
      text_body: %{"en" => "Hi"},
      category: "transactional",
      status: "active",
      is_system: false
    }

    {:ok, template} = Templates.create_template(Map.merge(base, attrs))
    template
  end

  describe "request_archive" do
    test "on a system template populates the confirmation modal and does not archive yet" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_archive", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "archive_template"
      assert updated.assigns.confirmation_modal.uuid == template.uuid

      assert Templates.get_template(template.uuid).status == "active"
    end

    test "on a non-system template archives immediately, no modal shown" do
      template = create_custom_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_archive", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal == %{show: false}
      assert Templates.get_template(template.uuid).status == "archived"
    end
  end

  describe "confirm_action archive_template" do
    test "actually archives the system template and hides the modal" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "confirm_action",
                 %{"action" => "archive_template", "uuid" => template.uuid},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == false
      assert Templates.get_template(template.uuid).status == "archived"
      assert updated.assigns.flash["info"] =~ template.name
    end
  end

  describe "request_activate" do
    test "on an archived system template populates the confirmation modal and does not activate yet" do
      template = create_system_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_activate", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "activate_template"
      assert updated.assigns.confirmation_modal.uuid == template.uuid

      assert Templates.get_template(template.uuid).status == "archived"
    end

    test "on a non-system archived template activates immediately, no modal shown" do
      template = create_custom_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_activate", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.confirmation_modal == %{show: false}
      assert Templates.get_template(template.uuid).status == "active"
    end
  end

  describe "confirm_action activate_template" do
    test "actually activates the archived system template and hides the modal" do
      template = create_system_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "confirm_action",
                 %{"action" => "activate_template", "uuid" => template.uuid},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == false
      assert Templates.get_template(template.uuid).status == "active"
      assert updated.assigns.flash["info"] =~ template.name
    end
  end

  describe "delete still rejected for system templates (regression guard)" do
    test "request_delete still opens the modal unconditionally (unchanged behavior)" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "request_delete",
                 %{"uuid" => template.uuid, "name" => template.name},
                 socket
               )

      assert updated.assigns.confirmation_modal.show == true
      assert updated.assigns.confirmation_modal.action == "delete_template"
    end

    test "delete_template rejects a system template" do
      template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("delete_template", %{"uuid" => template.uuid}, socket)

      assert updated.assigns.flash["error"] =~ "cannot be deleted"
      assert Templates.get_template(template.uuid) != nil
    end
  end

  describe "clone_template" do
    test "clones with the display name typed into the modal" do
      source = create_custom_template()
      name = "cloned_#{System.unique_integer([:positive])}"

      socket = bare_socket(%{clone_template: source, clone_form: %{name: "", display_name: ""}})

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "clone_template",
                 %{"clone" => %{"name" => name, "display_name" => "My Copy"}},
                 socket
               )

      refute updated.assigns.flash["error"]
      clone = Templates.get_template_by_name(name)
      assert clone.display_name == %{"en" => "My Copy"}
      assert clone.is_system == false
    end

    test "rejects a reserved name inline, before anything is submitted" do
      source = create_custom_template()

      socket = bare_socket(%{clone_template: source, clone_form: %{name: "", display_name: ""}})

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "validate_clone",
                 %{
                   "clone" => %{
                     "name" => "new_login_alert",
                     "display_name" => "New Login Alert Copy"
                   }
                 },
                 socket
               )

      assert updated.assigns.clone_form.errors.name =~ "reserved"

      assert {:noreply, _} =
               TemplatesLive.handle_event(
                 "clone_template",
                 %{
                   "clone" => %{
                     "name" => "new_login_alert",
                     "display_name" => "New Login Alert Copy"
                   }
                 },
                 socket
               )

      assert Templates.get_template_by_name("new_login_alert") == nil
    end
  end

  describe "render" do
    defp base_list_assigns(templates) do
      %{
        stats: Templates.get_template_stats(),
        loading: false,
        filters: %{search: "", category: "", status: "", is_system: ""},
        templates: templates,
        display_locale: "en",
        sort_by: :inserted_at,
        sort_dir: :desc,
        page: 1,
        per_page: 25,
        total_count: length(templates),
        total_pages: 1,
        show_clone_modal: false,
        clone_template: nil,
        clone_form: %{name: "", display_name: "", errors: %{}},
        confirmation_modal: %{show: false}
      }
    end

    defp render_list(templates) do
      render_component(&TemplatesLive.render/1, base_list_assigns(templates),
        endpoint: PhoenixKitEmails.Test.StubEndpoint
      )
    end

    test "Archive button appears (by unique id) for a system template row, Delete does not" do
      system_template = create_system_template()
      custom_template = create_custom_template()

      html = render_list([system_template, custom_template])

      # Scoped to this specific row via its uuid-suffixed id — a mutation
      # that hides Archive/Activate for system rows again must fail this,
      # unlike a bare substring check for "request_archive" (which the
      # custom row's own button would also satisfy).
      assert html =~ ~s|id="archive-template-#{system_template.uuid}"|
      assert html =~ ~s|id="archive-template-card-#{system_template.uuid}"|

      # The system row must not carry a delete button — id-scoped, not a
      # bare phx-value-name check (the custom row's own delete button also
      # carries a phx-value-name, so that alone wouldn't catch a mutation
      # that re-shows delete for system rows).
      refute html =~ ~s|id="delete-template-#{system_template.uuid}"|
      refute html =~ ~s|id="delete-template-card-#{system_template.uuid}"|

      # The custom row still gets both.
      assert html =~ ~s|id="archive-template-#{custom_template.uuid}"|
      assert html =~ ~s|id="delete-template-#{custom_template.uuid}"|
    end

    test "Activate button appears (by unique id) for an archived system template row" do
      system_template = create_system_template(%{status: "archived"})

      html = render_list([system_template])

      assert html =~ ~s|id="activate-template-#{system_template.uuid}"|
      refute html =~ ~s|id="archive-template-#{system_template.uuid}"|
    end

    test "the confirmation modal renders the system-specific archive warning text" do
      system_template = create_system_template()
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "request_archive",
                 %{"uuid" => system_template.uuid},
                 socket
               )

      assigns =
        base_list_assigns([system_template])
        |> Map.put(:confirmation_modal, updated.assigns.confirmation_modal)

      html =
        render_component(&TemplatesLive.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      assert html =~ ~s|id="template-confirm-modal"|
      # The template name and the specific, non-generic claims the copy
      # makes — a mutation that shortens or genericizes the warning (e.g.
      # back to the old unconditional "HTML version will be lost") must fail
      # at least one of these.
      assert html =~ system_template.name
      assert html =~ "translations"
      assert html =~ "file override"
      assert html =~ "reactivate"
    end

    test "the confirmation modal renders the test_email-specific warning" do
      # "test_email" is one of the nine names default_system_templates/0
      # seeds — some other test file in the suite (e.g. a boot/migration
      # test that seeds outside a rolled-back sandbox transaction) may
      # already have left a permanent row under this name in the shared
      # physical test database, so create-or-reuse like seed_system_templates/0
      # itself does, rather than assuming the name is free.
      test_email =
        Templates.get_template_by_name("test_email") ||
          create_system_template(%{name: "test_email", slug: "test-email"})

      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event("request_archive", %{"uuid" => test_email.uuid}, socket)

      assigns =
        base_list_assigns([test_email])
        |> Map.put(:confirmation_modal, updated.assigns.confirmation_modal)

      html =
        render_component(&TemplatesLive.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      assert html =~ "test-send"
      assert html =~ "built-in English template"
    end

    test "the activate confirmation button is not styled as an error/destructive action" do
      system_template = create_system_template(%{status: "archived"})
      socket = bare_socket()

      assert {:noreply, updated} =
               TemplatesLive.handle_event(
                 "request_activate",
                 %{"uuid" => system_template.uuid},
                 socket
               )

      assigns =
        base_list_assigns([system_template])
        |> Map.put(:confirmation_modal, updated.assigns.confirmation_modal)

      html =
        render_component(&TemplatesLive.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      refute html =~ ~s|class="btn btn-error"|
    end
  end
end
