defmodule PhoenixKit.Modules.Emails.Web.TemplateEditorPreviewTest do
  @moduledoc """
  The editor's live preview and its visible text (#46, #50):

    * the preview is the template as edited so far, in the tab's language,
      with sample values in place of `{{variables}}`;
    * the preview iframe is patched when its content changes (an element
      marked `phx-update="ignore"` never gets a new `srcdoc`);
    * the page title, subtitle, placeholders and variable hints go through the
      module's gettext, and the editor does not write English variable
      descriptions into the row.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor
  alias PhoenixKitEmails.Test.Repo

  @gettext PhoenixKit.Modules.Emails.Gettext

  setup do
    original = Gettext.get_locale(@gettext)
    on_exit(fn -> Gettext.put_locale(@gettext, original) end)
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp create!(overrides \\ %{}) do
    n = unique()

    {:ok, template} =
      Templates.create_template(
        Map.merge(
          %{
            name: "preview_#{n}",
            slug: "preview-#{n}",
            display_name: %{"en" => "Preview"},
            subject: %{"en" => "Welcome {{user_name}}"},
            html_body: %{"en" => "<p>Hello {{user_name}}, open {{url}}</p>"},
            text_body: %{"en" => "Hello {{user_name}}, open {{url}}"},
            variables: %{"user_name" => "", "url" => ""},
            category: "transactional",
            status: "active"
          },
          overrides
        )
      )

    template
  end

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp assigns(template, overrides) do
    Map.merge(
      %{
        changeset: Template.changeset(template, %{}),
        mode: :edit,
        template: template,
        available_locales: ["en", "et", "ru"],
        current_editor_locale: "en",
        preview_mode: "html",
        show_test_modal: false,
        test_sending: false,
        test_form: %{recipient: "", sample_variables: %{}, errors: %{}},
        extracted_variables: [],
        saving: false
      },
      overrides
    )
  end

  defp render_editor(template, overrides \\ %{}) do
    render_component(&TemplateEditor.render/1, assigns(template, overrides),
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # The iframe's document, as the browser would read the attribute.
  defp srcdoc(html) do
    [_, value] = Regex.run(~r/<iframe[^>]*\ssrcdoc="([^"]*)"/s, html)
    unescape(value)
  end

  # Only the preview card — the form above it holds the raw, stored text.
  defp pane(html), do: html |> String.split("Live Preview") |> List.last()

  defp iframe_tag(html), do: hd(Regex.run(~r/<iframe[^>]*>/s, html))

  describe "the preview substitutes sample values (#46)" do
    test "a new template starts with bodies in the selected locale" do
      socket = bare_socket(%{current_editor_locale: "et", available_locales: ["et", "en"]})

      assert {:noreply, socket} =
               TemplateEditor.handle_params(%{"display_name" => "New email"}, "http://x/", socket)

      changeset = socket.assigns.changeset
      assert Ecto.Changeset.get_field(changeset, :display_name) == %{"et" => "New email"}
      assert Ecto.Changeset.get_field(changeset, :html_body)["et"] =~ "Hello {{user_name}}"
      assert Ecto.Changeset.get_field(changeset, :text_body)["et"] =~ "Hello {{user_name}}"
      assert socket.assigns.extracted_variables == ["subject", "url", "user_name"]
      assert TemplateEditor.preview(changeset, "et").html_body =~ "Hello John Doe"
    end

    test "the HTML preview has no placeholders left" do
      html = render_editor(create!())

      doc = srcdoc(html)
      assert doc =~ "Hello John Doe, open https://example.com/action"
      refute doc =~ "{{"
    end

    test "the subject preview is substituted" do
      pane = create!() |> render_editor() |> pane()

      assert pane =~ "Welcome John Doe"
      refute pane =~ "{{user_name}}"
    end

    test "the text preview is substituted" do
      pane = create!() |> render_editor(%{preview_mode: "text"}) |> pane()

      assert pane =~ "Hello John Doe, open https://example.com/action"
      refute pane =~ "{{url}}"
    end

    test "a variable without a known sample gets a generic one" do
      template =
        create!(%{
          html_body: %{"en" => "<p>{{loyalty_points}}</p>"},
          variables: %{"user_name" => "", "url" => "", "loyalty_points" => ""}
        })

      assert srcdoc(render_editor(template)) =~ "<p>Sample loyalty_points</p>"
    end

    test "the preview is built from the changeset, not from the stored row" do
      template = create!()

      changeset =
        Template.changeset(template, %{
          "html_body" => %{"en" => "<p>EDITED {{user_name}}</p>"},
          "subject" => %{"en" => "EDITED SUBJECT"},
          "variables" => %{"user_name" => ""}
        })

      html = render_editor(template, %{changeset: changeset})

      assert srcdoc(html) =~ "<p>EDITED John Doe</p>"
      assert pane(html) =~ "EDITED SUBJECT"
    end

    test "an event that changes the form changes the preview" do
      template = create!()
      socket = bare_socket(assigns(template, %{}))

      assert {:noreply, updated} =
               TemplateEditor.handle_event(
                 "validate",
                 %{
                   "email_template" => %{
                     "html_body" => %{"en" => "<p>TYPED {{user_name}}</p>"},
                     "subject" => %{"en" => "TYPED SUBJECT"},
                     "text_body" => %{"en" => "typed"}
                   }
                 },
                 socket
               )

      html =
        render_editor(template, Map.take(updated.assigns, [:changeset, :extracted_variables]))

      assert srcdoc(html) =~ "<p>TYPED John Doe</p>"
      assert pane(html) =~ "TYPED SUBJECT"
    end

    test "the iframe can be patched: it is not marked phx-update=ignore" do
      refute iframe_tag(render_editor(create!())) =~ "phx-update"
    end

    test "the height the browser sets on the iframe survives a patch" do
      # Without phx-update="ignore" a patch with an unchanged srcdoc would
      # reset the `style` the onload handler wrote, back to 400px and a
      # scrollbar. The attribute is marked as one the server leaves alone.
      tag = iframe_tag(render_editor(create!()))

      assert tag =~ "phx-mounted="
      [_, mounted] = Regex.run(~r/phx-mounted="([^"]*)"/, tag)
      assert unescape(mounted) =~ ~s("ignore_attrs")
      assert unescape(mounted) =~ ~s(["style"])
      assert tag =~ "onload="
    end
  end

  describe "the preview follows the language tab (#46)" do
    defp multilingual do
      create!(%{
        subject: %{"en" => "EN {{user_name}}", "et" => "ET {{user_name}}"},
        html_body: %{"en" => "<p>EN {{user_name}}</p>", "et" => "<p>ET {{user_name}}</p>"},
        text_body: %{"en" => "EN {{user_name}}", "et" => "ET {{user_name}}"}
      })
    end

    test "each tab previews its own language" do
      template = multilingual()

      en = render_editor(template, %{current_editor_locale: "en"})
      assert srcdoc(en) =~ "<p>EN John Doe</p>"
      assert pane(en) =~ "EN John Doe"

      et = render_editor(template, %{current_editor_locale: "et"})
      assert srcdoc(et) =~ "<p>ET John Doe</p>"
      assert pane(et) =~ "ET John Doe"
    end

    test "a language without text previews the fallback a reader would get" do
      assert srcdoc(render_editor(multilingual(), %{current_editor_locale: "ru"})) =~
               "<p>EN John Doe</p>"
    end

    test "a regional tab previews the base language's text" do
      template = multilingual()
      tabs = ["en-US", "et", "ru"]

      html = render_editor(template, %{available_locales: tabs, current_editor_locale: "en-US"})

      assert srcdoc(html) =~ "<p>EN John Doe</p>"
      assert pane(html) =~ "EN John Doe"
    end

    test "a regional tab with its own text previews that" do
      template =
        create!(%{
          html_body: %{"en" => "<p>BASE {{user_name}}</p>", "en-US" => "<p>US {{user_name}}</p>"}
        })

      html =
        render_editor(template, %{
          available_locales: ["en-US", "et"],
          current_editor_locale: "en-US"
        })

      assert srcdoc(html) =~ "<p>US John Doe</p>"
    end
  end

  describe "titles and labels are translated (#50)" do
    defp assign_available(socket, locales),
      do: Phoenix.Component.assign(socket, :available_locales, locales)

    defp edit_socket(template) do
      bare_socket(%{current_editor_locale: "en", available_locales: ["en", "et"]})
      |> then(&TemplateEditor.handle_params(%{"id" => template.uuid}, "http://x/", &1))
      |> then(fn {:noreply, socket} -> socket end)
    end

    test "the edit page title and subtitle follow the locale" do
      template = create!()

      Gettext.put_locale(@gettext, "en")
      en = edit_socket(template)
      assert en.assigns.page_title == "Edit Template: Preview"
      assert en.assigns.page_subtitle == "Version 1 • Transactional • Custom • Active"

      Gettext.put_locale(@gettext, "et")
      et = edit_socket(template)
      assert et.assigns.page_title == "Muuda malli: Preview"
      assert et.assigns.page_subtitle == "Versioon 1 • Tehinguline • Kohandatud • Aktiivne"

      Gettext.put_locale(@gettext, "ru")
      ru = edit_socket(template)
      assert ru.assigns.page_title == "Редактирование шаблона: Preview"
      refute ru.assigns.page_subtitle =~ "Transactional"
      refute ru.assigns.page_subtitle =~ "Version"
    end

    test "the title names the template in the editor's language, not only English" do
      template = create!(%{display_name: %{"en" => "English name", "et" => "Eesti nimi"}})

      socket =
        bare_socket(%{current_editor_locale: "et", available_locales: ["et"]})

      assert {:noreply, socket} =
               TemplateEditor.handle_params(%{"id" => template.uuid}, "http://x/", socket)

      assert socket.assigns.page_title =~ "Eesti nimi"
      refute socket.assigns.page_title =~ "English name"
    end

    test "a regional editor language names the template by its own key" do
      template = create!(%{display_name: %{"en" => "Base name", "en-US" => "US name"}})

      socket =
        bare_socket(%{current_editor_locale: "en-US", available_locales: ["en-US"]})

      assert {:noreply, socket} =
               TemplateEditor.handle_params(%{"id" => template.uuid}, "http://x/", socket)

      assert socket.assigns.page_title =~ "US name"
    end

    test "the create page title is translated" do
      Gettext.put_locale(@gettext, "et")

      assert {:noreply, socket} = TemplateEditor.handle_params(%{}, "http://x/", bare_socket())
      assert socket.assigns.page_title == "Loo uus mall"
    end

    test "the subtitle names a known category, source module and status by their labels" do
      template =
        create!(%{category: "marketing", metadata: %{"source_module" => "users"}})

      socket = edit_socket(template)
      assert socket.assigns.page_subtitle == "Version 1 • Marketing • Users • Active"
    end

    test "a category, status or source module with no label is shown as stored, capitalised" do
      # The changeset would refuse these values, so a row from an older
      # version or another writer is simulated underneath it.
      template = create!()

      {1, _} =
        Repo.update_all(
          from(t in Template, where: t.uuid == ^template.uuid),
          set: [
            category: "seasonal",
            status: "retired",
            metadata: %{"source_module" => "legacy"}
          ]
        )

      socket = edit_socket(Repo.get!(Template, template.uuid))
      assert socket.assigns.page_subtitle == "Version 1 • Seasonal • Legacy • Retired"
    end

    test "the title follows the language tab" do
      template = create!(%{display_name: %{"en" => "English name", "et" => "Eesti nimi"}})
      socket = edit_socket(template)
      assert socket.assigns.page_title == "Edit Template: English name"

      assert {:noreply, socket} =
               TemplateEditor.handle_event("switch_editor_locale", %{"locale" => "et"}, socket)

      assert socket.assigns.current_editor_locale == "et"
      assert socket.assigns.page_title == "Edit Template: Eesti nimi"
    end

    test "a tab that is not offered leaves the title and the tab alone" do
      template = create!(%{display_name: %{"en" => "English name", "ru" => "Русское имя"}})
      socket = edit_socket(template)

      assert {:noreply, same} =
               TemplateEditor.handle_event("switch_editor_locale", %{"locale" => "ru"}, socket)

      assert same.assigns.current_editor_locale == "en"
      assert same.assigns.page_title == "Edit Template: English name"
    end

    test "switching tabs on the create page keeps its title" do
      assert {:noreply, socket} = TemplateEditor.handle_params(%{}, "http://x/", bare_socket())
      socket = assign_available(socket, ["en", "et"])

      assert {:noreply, socket} =
               TemplateEditor.handle_event("switch_editor_locale", %{"locale" => "et"}, socket)

      assert socket.assigns.current_editor_locale == "et"
      assert socket.assigns.page_title == "Create New Template"
    end

    test "the display name placeholder is translated" do
      template = create!()

      Gettext.put_locale(@gettext, "et")
      assert render_editor(template) =~ ~s(placeholder="Tervitusmeil")

      Gettext.put_locale(@gettext, "en")
      assert render_editor(template) =~ ~s(placeholder="Welcome Email")
    end

    test "the test-send form's errors are translated" do
      socket = bare_socket(%{test_form: %{recipient: "", sample_variables: %{}, errors: %{}}})
      blank = %{"test" => %{"recipient" => " "}}
      bad = %{"test" => %{"recipient" => "nobody"}}

      for {locale, required, invalid} <- [
            {"en", "Email address is required", "Please enter a valid email address"},
            {"et", "E-posti aadress on kohustuslik", "Sisesta kehtiv e-posti aadress"},
            {"ru", "Адрес электронной почты обязателен",
             "Введите корректный адрес электронной почты"}
          ] do
        Gettext.put_locale(@gettext, locale)

        assert {:noreply, s} = TemplateEditor.handle_event("validate_test", blank, socket)
        assert s.assigns.test_form.errors.recipient == required

        assert {:noreply, s} = TemplateEditor.handle_event("validate_test", bad, socket)
        assert s.assigns.test_form.errors.recipient == invalid
      end
    end

    test "the field placeholders are translated and keep the language code" do
      template = create!()

      Gettext.put_locale(@gettext, "et")

      html =
        template
        |> render_editor(%{current_editor_locale: "en", available_locales: ["en", "et"]})
        |> unescape()

      assert html =~ ~s|placeholder="Tere tulemast teenusesse {{app_name}}! (EN)"|
      assert html =~ ~s|placeholder="<h1>Tere tulemast, {{user_name}}!</h1> (EN)"|
      assert html =~ ~s|placeholder="Tere tulemast, {{user_name}}! (EN)"|
      refute html =~ "Welcome to {{app_name}}"
    end

    test "a regional tab's placeholder shows its full code" do
      html =
        render_editor(create!(), %{
          current_editor_locale: "en-US",
          available_locales: ["en-US", "et"]
        })

      assert html =~ "Welcome to {{app_name}}! (EN-US)"
    end
  end

  describe "variable descriptions (#50)" do
    defp validate(template, params) do
      socket = bare_socket(assigns(template, %{}))
      assert {:noreply, updated} = TemplateEditor.handle_event("validate", params, socket)
      Ecto.Changeset.get_field(updated.assigns.changeset, :variables)
    end

    test "detected variables are added without a description" do
      template = create!()

      variables =
        validate(template, %{
          "email_template" => %{
            "subject" => %{"en" => "Hi {{user_name}}"},
            "html_body" => %{"en" => "<p>{{user_name}} {{loyalty_points}}</p>"},
            "text_body" => %{"en" => "{{url}}"},
            "variables" => %{}
          }
        })

      assert variables == %{"user_name" => "", "loyalty_points" => "", "url" => ""}
    end

    test "a description the author typed is kept" do
      template = create!()

      variables =
        validate(template, %{
          "email_template" => %{
            "subject" => %{"en" => "Hi {{user_name}}"},
            "html_body" => %{"en" => "<p>{{user_name}}</p>"},
            "text_body" => %{"en" => "x"},
            "variables" => %{"user_name" => "Typed by the author"}
          }
        })

      assert variables == %{"user_name" => "Typed by the author"}
    end

    test "saving a new template stores empty descriptions, not English text" do
      n = unique()
      socket = bare_socket(%{mode: :new, saving: false, template: nil})

      assert {:noreply, _} =
               TemplateEditor.handle_event(
                 "save",
                 %{
                   "email_template" => %{
                     "name" => "described_#{n}",
                     "slug" => "described-#{n}",
                     "category" => "transactional",
                     "status" => "draft",
                     "display_name" => %{"en" => "Described"},
                     "subject" => %{"en" => "Hi {{user_name}}"},
                     "html_body" => %{"en" => "<p>{{user_name}} {{reset_url}}</p>"},
                     "text_body" => %{"en" => "{{user_name}}"}
                   },
                   "save_as" => "draft"
                 },
                 socket
               )

      saved = Templates.get_template_by_name("described_#{n}")
      assert saved.variables == %{"user_name" => "", "reset_url" => ""}
    end

    test "the field shows the translated hint as a placeholder while the description is empty" do
      template = create!()

      html = render_editor(template, %{extracted_variables: ["user_name", "url"]})
      assert unescape(html) =~ ~s(placeholder="User's display name")
      assert html =~ ~s(value="")

      Gettext.put_locale(@gettext, "et")

      assert unescape(render_editor(template, %{extracted_variables: ["user_name"]})) =~
               ~s(placeholder="Kasutaja kuvatav nimi")
    end

    test "a variable without a known hint gets a translated generic one" do
      template = create!(%{variables: %{"user_name" => "", "url" => "", "loyalty_points" => ""}})

      assigns = %{extracted_variables: ["loyalty_points"]}

      assert unescape(render_editor(template, assigns)) =~
               ~s(placeholder="Custom variable: loyalty_points")

      Gettext.put_locale(@gettext, "et")

      assert unescape(render_editor(template, assigns)) =~
               ~s(placeholder="Kohandatud muutuja: loyalty_points")
    end

    test "a stored description is shown as the value" do
      template = create!(%{variables: %{"user_name" => "Stored text", "url" => ""}})

      assert render_editor(template, %{extracted_variables: ["user_name"]}) =~
               ~s(value="Stored text")
    end
  end
end
