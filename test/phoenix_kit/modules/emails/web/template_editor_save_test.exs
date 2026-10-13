defmodule PhoenixKit.Modules.Emails.Web.TemplateEditorSaveTest do
  @moduledoc """
  What the editor's form does to a stored row (#45, #47):

    * a locale the template has no text for is rendered empty — never filled
      from the fallback — so saving one tab cannot write the fallback text
      into the others;
    * saving keeps the metadata keys the form does not carry;
    * `created_by_user_uuid` / `updated_by_user_uuid` come from the session's
      scope, and a form that carries them is ignored.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitEmails.Test.Repo

  @admin "01900000-0000-7000-8000-0000000000a1"
  @forged "01900000-0000-7000-8000-0000000000f0"

  defp bare_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end

  defp scope(uuid), do: %Scope{user: %User{uuid: uuid}}

  defp unique, do: System.unique_integer([:positive])

  defp create!(overrides \\ %{}) do
    n = unique()

    {:ok, template} =
      Templates.create_template(
        Map.merge(
          %{
            name: "editor_save_#{n}",
            slug: "editor-save-#{n}",
            display_name: %{"en" => "Editor save"},
            subject: %{"en" => "Subject"},
            html_body: %{"en" => "<p>Hi</p>"},
            text_body: %{"en" => "Hi"},
            category: "transactional",
            status: "active"
          },
          overrides
        )
      )

    template
  end

  # What the fixed form posts for the EN tab of a template with et/ru enabled
  # and no et/ru text: the tab's own value, and an empty string per other locale.
  defp en_tab_params(template, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => template.name,
        "slug" => template.slug,
        "category" => template.category,
        "status" => template.status,
        "display_name" => %{"en" => "Editor save", "et" => "", "ru" => ""},
        "subject" => %{"en" => "Subject edited", "et" => "", "ru" => ""},
        "html_body" => %{"en" => "<p>Hi!</p>", "et" => "", "ru" => ""},
        "text_body" => %{"en" => "Hi!", "et" => "", "ru" => ""},
        "description" => %{"en" => "", "et" => "", "ru" => ""}
      },
      overrides
    )
  end

  defp save(socket, params) do
    assert {:noreply, updated} =
             TemplateEditor.handle_event(
               "save",
               %{"email_template" => params, "save_as" => "active"},
               socket
             )

    updated
  end

  @locales ["en", "et", "ru"]

  defp editor_assigns(template, locale, tabs) do
    %{
      changeset: Template.changeset(template, %{}),
      mode: :edit,
      template: template,
      available_locales: tabs,
      current_editor_locale: locale,
      preview_mode: "html",
      show_test_modal: false,
      test_sending: false,
      test_form: %{recipient: "", sample_variables: %{}, errors: %{}},
      extracted_variables: [],
      saving: false
    }
  end

  defp render_editor(template, locale, tabs \\ @locales) do
    render_component(&TemplateEditor.render/1, editor_assigns(template, locale, tabs),
      endpoint: PhoenixKitEmails.Test.StubEndpoint
    )
  end

  # What the form would submit for `field[locale]`: the value attribute of an
  # input, or the content of a textarea. `nil` when the field is not rendered.
  defp form_value(html, field, locale) do
    pattern =
      ~r/name="email_template\[#{field}\]\[#{locale}\]"[^>]*?(?:value="([^"]*)"[^>]*>|>([^<]*)<\/textarea>)/

    value =
      case Regex.run(pattern, html, capture: :all_but_first) do
        [value] -> value
        [value, ""] -> value
        [_, value] -> value
        nil -> nil
      end

    value && unescape(value)
  end

  # What a browser hands back for an attribute or a textarea's text.
  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  describe "the form carries what is stored, nothing more (#45)" do
    test "hidden inputs for locales without text are empty, not the fallback" do
      template =
        create!(%{
          display_name: %{"en" => "ENGLISH-NAME"},
          description: %{"en" => "ENGLISH-DESCRIPTION"},
          subject: %{"en" => "ENGLISH-SUBJECT"},
          html_body: %{"en" => "ENGLISH-HTML"},
          text_body: %{"en" => "ENGLISH-TEXT"}
        })

      html = render_editor(template, "en")

      for field <- ~w(display_name description subject html_body text_body),
          locale <- ["et", "ru"] do
        assert form_value(html, field, locale) == "",
               "#{field}[#{locale}] carries the fallback text"
      end

      # …and the EN tab's own fields hold the stored English.
      assert form_value(html, "subject", "en") == "ENGLISH-SUBJECT"
      assert form_value(html, "text_body", "en") == "ENGLISH-TEXT"
    end

    test "an untranslated tab shows an empty field, and a translated one its text" do
      template =
        create!(%{
          subject: %{"en" => "ENGLISH-SUBJECT", "et" => "EESTI-TEEMA"},
          html_body: %{"en" => "ENGLISH-HTML"}
        })

      et = render_editor(template, "et")
      assert et =~ ~r/name="email_template\[subject\]\[et\]"[^>]*value="EESTI-TEEMA"/
      refute et =~ ~r/name="email_template\[html_body\]\[et\]"[^>]*>ENGLISH-HTML/

      ru = render_editor(template, "ru")
      refute ru =~ ~r/name="email_template\[subject\]\[ru\]"[^>]*value="[^"]+"/
    end

    test "the hidden inputs of a translated locale keep its text" do
      template = create!(%{subject: %{"en" => "ENGLISH-SUBJECT", "et" => "EESTI-TEEMA"}})

      html = render_editor(template, "en")

      assert html =~ ~r/name="email_template\[subject\]\[et\]"[^>]*value="EESTI-TEEMA"/
    end

    test "the preview still falls back, because that is what a reader would get" do
      template = create!(%{subject: %{"en" => "ENGLISH-SUBJECT"}})

      assert render_editor(template, "et") =~ "ENGLISH-SUBJECT"
    end

    test "saving the EN tab of an English-only template leaves et and ru out of the row" do
      template = create!()
      socket = bare_socket(%{mode: :edit, saving: false, template: template})

      save(socket, en_tab_params(template))

      saved = Templates.get_template(template.uuid)
      assert saved.subject == %{"en" => "Subject edited"}
      assert saved.html_body == %{"en" => "<p>Hi!</p>"}
      assert saved.text_body == %{"en" => "Hi!"}
      assert saved.display_name == %{"en" => "Editor save"}
    end

    test "translations that exist are kept when another tab is saved" do
      template = create!(%{subject: %{"en" => "Subject", "et" => "Teema"}})
      socket = bare_socket(%{mode: :edit, saving: false, template: template})

      params =
        en_tab_params(template, %{
          "subject" => %{"en" => "Subject 2", "et" => "Teema", "ru" => ""}
        })

      save(socket, params)

      assert Templates.get_template(template.uuid).subject ==
               %{"en" => "Subject 2", "et" => "Teema"}
    end

    test "a new template written in one language, with others enabled, can be saved" do
      n = unique()
      socket = bare_socket(%{mode: :new, saving: false, template: nil})

      params = %{
        "name" => "estonian_only_#{n}",
        "slug" => "estonian-only-#{n}",
        "category" => "transactional",
        "status" => "draft",
        "display_name" => %{"en" => "", "et" => "Tere", "ru" => ""},
        "subject" => %{"en" => "", "et" => "Tere", "ru" => ""},
        "html_body" => %{"en" => "", "et" => "<p>Tere</p>", "ru" => ""},
        "text_body" => %{"en" => "", "et" => "Tere", "ru" => ""}
      }

      save(socket, params)

      saved = Templates.get_template_by_name("estonian_only_#{n}")
      assert saved
      assert saved.subject == %{"et" => "Tere"}
    end

    test "a template with no text in any language is refused with an error on the field" do
      n = unique()
      socket = bare_socket(%{mode: :new, saving: false, template: nil})

      params = %{
        "name" => "nothing_#{n}",
        "slug" => "nothing-#{n}",
        "category" => "transactional",
        "status" => "draft",
        "display_name" => %{"en" => "Nothing"},
        "subject" => %{"en" => "", "et" => ""},
        "html_body" => %{"en" => "<p>x</p>"},
        "text_body" => %{"en" => "x"}
      }

      updated = save(socket, params)

      assert Templates.get_template_by_name("nothing_#{n}") == nil
      assert {msg, _} = Keyword.fetch!(updated.assigns.changeset.errors, :subject)
      assert msg =~ "at least one"
    end
  end

  describe "metadata survives a save (#47)" do
    test "validate and save preserve translations for languages without a tab" do
      translations = %{"en" => "English", "de" => "Deutsch", "en-GB" => "British"}

      template =
        create!(
          Map.new(
            [:display_name, :description, :subject, :html_body, :text_body],
            &{&1, translations}
          )
        )

      socket = bare_socket(editor_assigns(template, "en", @locales))
      params = en_tab_params(template)

      assert {:noreply, validated} =
               TemplateEditor.handle_event("validate", %{"email_template" => params}, socket)

      for field <- [:display_name, :description, :subject, :html_body, :text_body] do
        assert Ecto.Changeset.get_field(validated.assigns.changeset, field)["de"] == "Deutsch"
      end

      saved_socket = save(validated, params)
      saved = Templates.get_template(template.uuid)

      for field <- [:display_name, :description, :subject, :html_body, :text_body] do
        assert Map.get(saved, field)["de"] == "Deutsch"
        assert Map.get(saved, field)["en-GB"] == "British"
        refute Map.has_key?(Map.get(saved, field), "et")
      end

      refute Map.has_key?(saved.description, "en")
      assert Ecto.Changeset.apply_changes(saved_socket.assigns.changeset) == saved
    end

    test "saving synchronizes the form and preview even without a preceding validate" do
      template = create!()
      socket = bare_socket(editor_assigns(template, "en", @locales))

      updated =
        save(
          socket,
          en_tab_params(template, %{
            "display_name" => %{"en" => "Renamed"},
            "html_body" => %{"en" => "<p>Saved {{user_name}}</p>"}
          })
        )

      saved = Templates.get_template(template.uuid)
      assert Ecto.Changeset.apply_changes(updated.assigns.changeset) == saved
      assert updated.assigns.extracted_variables == ["user_name"]
      assert updated.assigns.page_title == "Edit Template: Renamed"
      assert updated.assigns.page_subtitle == "Version 2 • Transactional • Custom • Active"

      assert TemplateEditor.preview(updated.assigns.changeset, "en").html_body ==
               "<p>Saved John Doe</p>"
    end

    test "the editor's source_module is merged, cloned_from stays" do
      source = create!()
      {:ok, clone} = Templates.clone_template(source, "metadata_clone_#{unique()}")
      assert clone.metadata["cloned_from"] == source.uuid

      socket = bare_socket(%{mode: :edit, saving: false, template: clone})

      params =
        en_tab_params(clone, %{"metadata" => %{"source_module" => "billing"}})

      save(socket, params)

      assert Templates.get_template(clone.uuid).metadata ==
               %{"cloned_from" => source.uuid, "source_module" => "billing"}
    end

    test "a source_module outside the list is refused and nothing is saved" do
      template = create!(%{metadata: %{"source_module" => "users", "keep" => "me"}})
      socket = bare_socket(%{mode: :edit, saving: false, template: template})

      updated =
        save(socket, en_tab_params(template, %{"metadata" => %{"source_module" => "evil"}}))

      assert {msg, _} = Keyword.fetch!(updated.assigns.changeset.errors, :metadata)
      assert msg =~ "source_module"

      saved = Templates.get_template(template.uuid)
      assert saved.metadata == %{"source_module" => "users", "keep" => "me"}
      assert saved.version == template.version
    end
  end

  describe "audit columns (#47)" do
    test "creating records the scope's user as the author" do
      n = unique()

      socket =
        bare_socket(%{
          mode: :new,
          saving: false,
          template: nil,
          phoenix_kit_current_scope: scope(@admin)
        })

      save(socket, %{
        "name" => "audited_#{n}",
        "slug" => "audited-#{n}",
        "category" => "transactional",
        "status" => "draft",
        "display_name" => %{"en" => "Audited"},
        "subject" => %{"en" => "S"},
        "html_body" => %{"en" => "<p>x</p>"},
        "text_body" => %{"en" => "x"}
      })

      saved = Templates.get_template_by_name("audited_#{n}")
      assert saved.created_by_user_uuid == @admin
      assert saved.updated_by_user_uuid == nil
    end

    test "editing records the scope's user as the editor and bumps the version" do
      template = create!()

      socket =
        bare_socket(%{
          mode: :edit,
          saving: false,
          template: template,
          phoenix_kit_current_scope: scope(@admin)
        })

      save(socket, en_tab_params(template))

      saved = Templates.get_template(template.uuid)
      assert saved.updated_by_user_uuid == @admin
      assert saved.version == template.version + 1
      assert saved.created_by_user_uuid == nil
    end

    test "a form that carries the audit columns cannot set them" do
      template = create!()

      socket =
        bare_socket(%{
          mode: :edit,
          saving: false,
          template: template,
          phoenix_kit_current_scope: scope(@admin)
        })

      forged = %{"created_by_user_uuid" => @forged, "updated_by_user_uuid" => @forged}
      save(socket, en_tab_params(template, forged))

      saved = Templates.get_template(template.uuid)
      assert saved.updated_by_user_uuid == @admin
      assert saved.created_by_user_uuid == nil
    end

    test "with no scope, a forged value is still ignored and nothing is recorded" do
      template = create!()
      socket = bare_socket(%{mode: :edit, saving: false, template: template})

      save(
        socket,
        en_tab_params(template, %{
          "created_by_user_uuid" => @forged,
          "updated_by_user_uuid" => @forged
        })
      )

      saved = Templates.get_template(template.uuid)
      assert saved.updated_by_user_uuid == nil
      assert saved.created_by_user_uuid == nil
    end
  end

  describe "Templates context (#47)" do
    test "create_template/2 takes the author from opts and ignores string-keyed attrs" do
      n = unique()

      attrs = %{
        "name" => "ctx_create_#{n}",
        "slug" => "ctx-create-#{n}",
        "display_name" => %{"en" => "Ctx"},
        "subject" => %{"en" => "S"},
        "html_body" => %{"en" => "<p>x</p>"},
        "text_body" => %{"en" => "x"},
        "category" => "transactional",
        "status" => "draft",
        "created_by_user_uuid" => @forged
      }

      assert {:ok, forged} = Templates.create_template(attrs)
      assert forged.created_by_user_uuid == nil

      attrs2 = %{attrs | "name" => "ctx_create_b_#{n}", "slug" => "ctx-create-b-#{n}"}
      assert {:ok, owned} = Templates.create_template(attrs2, created_by_user_uuid: @admin)
      assert owned.created_by_user_uuid == @admin
    end

    test "update_template/3 keeps the recorded editor when none is given" do
      template = create!()

      {:ok, first} = Templates.update_template(template, %{}, updated_by_user_uuid: @admin)
      assert first.updated_by_user_uuid == @admin

      {:ok, second} = Templates.update_template(first, %{status: "draft"})
      assert second.updated_by_user_uuid == @admin
      assert second.version == first.version + 1
    end

    test "an atom-keyed audit column in attrs is ignored too" do
      template = create!()

      {:ok, updated} = Templates.update_template(template, %{updated_by_user_uuid: @forged})
      assert updated.updated_by_user_uuid == nil

      n = unique()

      {:ok, created} =
        Templates.create_template(%{
          name: "atom_author_#{n}",
          slug: "atom-author-#{n}",
          display_name: %{"en" => "Atom"},
          subject: %{"en" => "S"},
          html_body: %{"en" => "<p>x</p>"},
          text_body: %{"en" => "x"},
          category: "transactional",
          status: "draft",
          created_by_user_uuid: @forged
        })

      assert created.created_by_user_uuid == nil
    end

    test "update_template/3 ignores a string-keyed audit column in attrs" do
      template = create!()

      {:ok, updated} =
        Templates.update_template(template, %{"updated_by_user_uuid" => @forged})

      assert updated.updated_by_user_uuid == nil
    end

    test "archive_template/2 and activate_template/2 still record who did it" do
      template = create!()

      {:ok, archived} = Templates.archive_template(template, @admin)
      assert archived.status == "archived"
      assert archived.updated_by_user_uuid == @admin

      {:ok, activated} = Templates.activate_template(archived, @forged)
      assert activated.status == "active"
      assert activated.updated_by_user_uuid == @forged
    end

    test "clone_template/3 records its author and keeps the source's metadata" do
      source = create!(%{metadata: %{"source_module" => "billing"}})

      {:ok, clone} =
        Templates.clone_template(source, "ctx_clone_#{unique()}", %{},
          created_by_user_uuid: @admin
        )

      assert clone.created_by_user_uuid == @admin
      assert clone.metadata == %{"source_module" => "billing", "cloned_from" => source.uuid}
    end

    test "an author that is not a UUID is a changeset error, not a crash" do
      n = unique()

      assert {:error, changeset} =
               Templates.create_template(
                 %{
                   name: "ctx_bad_#{n}",
                   slug: "ctx-bad-#{n}",
                   display_name: %{"en" => "Bad"},
                   subject: %{"en" => "S"},
                   html_body: %{"en" => "<p>x</p>"},
                   text_body: %{"en" => "x"},
                   category: "transactional",
                   status: "draft"
                 },
                 created_by_user_uuid: "not-a-uuid"
               )

      assert Keyword.has_key?(changeset.errors, :created_by_user_uuid)
    end
  end

  describe "regional language codes (#45)" do
    # What a host with en-US/et/ru enabled has: rows seeded under "en".
    @regional ["en-US", "et", "ru"]

    # The editor's form for `tabs`, as the browser would submit it untouched:
    # every field of every tab, as rendered.
    defp submitted_untouched(html, tabs) do
      for field <- ~w(display_name description subject html_body text_body), into: %{} do
        {field, Map.new(tabs, fn locale -> {locale, form_value(html, field, locale) || ""} end)}
      end
    end

    test "the first en-* tab shows the base key's text, the others do not" do
      template = create!(%{subject: %{"en" => "ENGLISH-SUBJECT"}})

      us = render_editor(template, "en-US", ["en-US", "en-GB", "et"])
      assert form_value(us, "subject", "en-US") == "ENGLISH-SUBJECT"
      assert form_value(us, "subject", "en-GB") == ""

      gb = render_editor(template, "en-GB", ["en-US", "en-GB", "et"])
      assert form_value(gb, "subject", "en-US") == "ENGLISH-SUBJECT"
      assert form_value(gb, "subject", "en-GB") == ""
    end

    test "every field reads the base key, on the visible tab and as a hidden input" do
      template =
        create!(%{
          display_name: %{"en" => "ENGLISH-NAME"},
          description: %{"en" => "ENGLISH-DESCRIPTION"},
          subject: %{"en" => "ENGLISH-SUBJECT"},
          html_body: %{"en" => "ENGLISH-HTML"},
          text_body: %{"en" => "ENGLISH-TEXT"}
        })

      expected = %{
        "display_name" => "ENGLISH-NAME",
        "description" => "ENGLISH-DESCRIPTION",
        "subject" => "ENGLISH-SUBJECT",
        "html_body" => "ENGLISH-HTML",
        "text_body" => "ENGLISH-TEXT"
      }

      for current <- ["en-US", "et"], {field, text} <- expected do
        html = render_editor(template, current, @regional)

        assert form_value(html, field, "en-US") == text,
               "#{field}[en-US] on the #{current} tab"
      end
    end

    test "a base code that is a tab of its own is not copied into the regional one" do
      template = create!(%{subject: %{"en" => "ENGLISH-SUBJECT"}})

      html = render_editor(template, "en", ["en", "en-US"])

      assert form_value(html, "subject", "en") == "ENGLISH-SUBJECT"
      assert form_value(html, "subject", "en-US") == ""

      # …whichever tab comes first.
      html = render_editor(template, "en", ["en-US", "en"])

      assert form_value(html, "subject", "en") == "ENGLISH-SUBJECT"
      assert form_value(html, "subject", "en-US") == ""
    end

    test "an en-US tab with its own text keeps it, and the base key is not shown beside it" do
      template = create!(%{subject: %{"en" => "BASE", "en-US" => "AMERICAN"}})

      html = render_editor(template, "en-US", @regional)

      assert form_value(html, "subject", "en-US") == "AMERICAN"
    end

    test "an English-only template opened on en-US is saved without retyping anything" do
      template = create!()
      html = render_editor(template, "en-US", @regional)
      form = submitted_untouched(html, @regional)

      assert form["subject"]["en-US"] == "Subject"

      socket = bare_socket(%{mode: :edit, saving: false, template: template})

      updated =
        save(socket, %{
          "name" => template.name,
          "slug" => template.slug,
          "category" => template.category,
          "status" => template.status,
          "display_name" => form["display_name"],
          "description" => form["description"],
          "subject" => form["subject"],
          "html_body" => form["html_body"],
          "text_body" => form["text_body"]
        })

      assert updated.assigns.flash["info"] =~ "updated successfully"
      saved = Templates.get_template(template.uuid)
      assert saved.version == template.version + 1
      assert saved.subject == %{"en" => "Subject", "en-US" => "Subject"}
      assert saved.html_body == %{"en" => "<p>Hi</p>", "en-US" => "<p>Hi</p>"}
      assert Template.get_translation(saved.subject, "et") == "Subject"
    end
  end

  describe "a clone keeps its source's metadata as stored (#47)" do
    test "a source_module this version would refuse from a form does not stop the clone" do
      source = create!()

      source =
        source
        |> Ecto.Changeset.change(metadata: %{"source_module" => "legacy_module", "n" => 1})
        |> Repo.update!()

      assert {:ok, clone} = Templates.clone_template(source, "legacy_clone_#{unique()}")

      assert clone.metadata ==
               %{"source_module" => "legacy_module", "n" => 1, "cloned_from" => source.uuid}
    end

    test "the clone's own form is still checked" do
      source = create!()

      assert {:error, changeset} =
               Templates.clone_template(source, "bad_meta_clone_#{unique()}", %{
                 metadata: %{"source_module" => "evil"}
               })

      assert Keyword.has_key?(changeset.errors, :metadata)
    end
  end
end
