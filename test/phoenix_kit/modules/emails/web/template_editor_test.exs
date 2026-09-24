defmodule PhoenixKit.Modules.Emails.Web.TemplateEditorTest do
  @moduledoc """
  The "New Template" form never sends `is_system` (it only appears as
  `disabled=` on system rows being edited, and disabled fields aren't
  submitted), so this is the LiveView-side check that the changeset's
  reserved-name guard (`PhoenixKit.Modules.Emails.Template`) actually blocks
  the save and surfaces a readable error, not just that the context function
  does.

  Also covers a crafted "save" event that isn't limited to what the rendered
  form submits — a LiveView event is just a map the client controls, so a
  request that adds `is_system: true` or a `status` change for an existing
  system template must be rejected the same way a form submission is.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor

  defp bare_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp reserved_params(name) do
    %{
      "name" => name,
      "slug" => String.replace(name, "_", "-"),
      "display_name" => %{"en" => "Some Display Name"},
      "subject" => %{"en" => "A subject"},
      "html_body" => %{"en" => "<p>Hi</p>"},
      "text_body" => %{"en" => "Hi"},
      "category" => "system",
      "status" => "draft"
    }
  end

  test "save on a :new socket rejects an unseeded reserved name and does not create a template" do
    socket = bare_socket(%{mode: :new, saving: false, template: nil})

    assert {:noreply, updated} =
             TemplateEditor.handle_event(
               "save",
               %{"email_template" => reserved_params("new_login_alert"), "save_as" => "active"},
               socket
             )

    assert updated.assigns.saving == false
    refute Map.has_key?(updated.assigns.flash, "info")

    changeset = updated.assigns.changeset
    refute changeset.valid?
    assert {msg, _} = Keyword.get(changeset.errors, :name)
    assert msg =~ "reserved"

    # Not created.
    assert Templates.get_template_by_name("new_login_alert") == nil
  end

  test "a crafted is_system: true in the save event does not bypass the reserved-name guard" do
    socket = bare_socket(%{mode: :new, saving: false, template: nil})

    params = reserved_params("failed_login_alert") |> Map.put("is_system", "true")

    assert {:noreply, updated} =
             TemplateEditor.handle_event(
               "save",
               %{"email_template" => params, "save_as" => "active"},
               socket
             )

    changeset = updated.assigns.changeset
    refute changeset.valid?
    assert {msg, _} = Keyword.get(changeset.errors, :name)
    assert msg =~ "reserved"

    assert Templates.get_template_by_name("failed_login_alert") == nil
  end

  describe "system template status is protected from the editor" do
    test "a crafted status change in the save event does not archive an existing system template" do
      {:ok, seeded} = Templates.seed_system_templates()
      system_template = Enum.find(seeded, & &1.is_system)

      socket =
        bare_socket(%{mode: :edit, saving: false, template: system_template})

      params =
        reserved_params(system_template.name)
        |> Map.put("status", "archived")

      assert {:noreply, _updated} =
               TemplateEditor.handle_event(
                 "save",
                 %{"email_template" => params, "save_as" => "active"},
                 socket
               )

      assert Templates.get_template(system_template.uuid).status == "active"
    end

    test "a non-system template's status is unaffected by the guard" do
      {:ok, custom} =
        Templates.create_template(%{
          name: "custom_status_#{System.unique_integer([:positive])}",
          slug: "custom-status-#{System.unique_integer([:positive])}",
          display_name: %{"en" => "Custom"},
          subject: %{"en" => "Subject"},
          html_body: %{"en" => "<p>Hi</p>"},
          text_body: %{"en" => "Hi"},
          category: "transactional",
          status: "active"
        })

      socket = bare_socket(%{mode: :edit, saving: false, template: custom})

      params = reserved_params(custom.name) |> Map.put("status", "archived")

      assert {:noreply, _updated} =
               TemplateEditor.handle_event(
                 "save",
                 %{"email_template" => params, "save_as" => "active"},
                 socket
               )

      assert Templates.get_template(custom.uuid).status == "archived"
    end
  end

  describe "render — Status select lock" do
    defp editor_assigns(template) do
      %{
        changeset: Template.changeset(template, %{}),
        mode: :edit,
        template: template,
        available_locales: ["en"],
        current_editor_locale: "en",
        preview_mode: "html",
        show_test_modal: false,
        test_sending: false,
        test_form: %{recipient: "", sample_variables: %{}, errors: %{}},
        extracted_variables: [],
        saving: false
      }
    end

    test "the Status select is disabled for an existing system template" do
      {:ok, seeded} = Templates.seed_system_templates()
      system_template = Enum.find(seeded, & &1.is_system)

      html =
        render_component(&TemplateEditor.render/1, editor_assigns(system_template),
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      assert Regex.match?(~r/name="email_template\[status\]"[^>]*disabled/, html)
    end

    test "the Status select is not disabled for a non-system template" do
      {:ok, custom} =
        Templates.create_template(%{
          name: "custom_status_render_#{System.unique_integer([:positive])}",
          slug: "custom-status-render-#{System.unique_integer([:positive])}",
          display_name: %{"en" => "Custom"},
          subject: %{"en" => "Subject"},
          html_body: %{"en" => "<p>Hi</p>"},
          text_body: %{"en" => "Hi"},
          category: "transactional",
          status: "active"
        })

      html =
        render_component(&TemplateEditor.render/1, editor_assigns(custom),
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      refute Regex.match?(~r/name="email_template\[status\]"[^>]*disabled/, html)
    end
  end
end
