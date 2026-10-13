defmodule PhoenixKit.Modules.Emails.TemplateSourcesTest do
  @moduledoc """
  Which layer a send would use for a template name (#48): core resolves
  `active database row → host file override → module/core default`, so an
  active row hides the two below it. `TemplateSources` finds out, read-only,
  whether a file override and a default exist for a row's name, and the badges
  say so on the templates list and in the editor.

  Not every core API it reads is in this package's `phoenix_kit` floor (2.21.3):
  `PhoenixKit.Email.Content.override_paths/0` is, `PhoenixKit.Email.Catalog.entries/0`
  arrived in 2.44.0 and `PhoenixKit.Templates.Overrides.list/1` with
  `phoenix_kit_templates` 0.2.3 (cores 2.44 to 2.61 accept `~> 0.2.2`). On a core
  without one, nothing is shown instead of failing.
  """

  use PhoenixKitEmails.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.TemplateSources
  alias PhoenixKit.Modules.Emails.Web.SourceBadges
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor
  alias PhoenixKit.Modules.Emails.Web.Templates, as: TemplatesLive

  # A core that predates the file-listing API: the module is there, `list/1` is not.
  defmodule OldOverrides do
    def read(_roots, _name, _part, _locale), do: nil
  end

  defmodule BrokenOverrides do
    def list(_root), do: raise("a root that cannot be read")
  end

  defmodule BrokenCatalog do
    def entries, do: raise("a module's catalog entry blew up")
  end

  defmodule FakeCatalog do
    def entries do
      [
        %{name: "core_mail", label: "Core mail", defaults: %{text: "Core"}, module: nil},
        %{
          name: "billing_mail",
          label: "Billing mail",
          defaults: fn -> %{text: "Billing"} end,
          module: PhoenixKitBilling
        }
      ]
    end
  end

  defmodule CatalogWithoutDefaults do
    def entries do
      [
        %{name: "no_defaults"},
        %{name: "empty_defaults", defaults: %{}},
        %{name: "label_only", defaults: %{label: "A label"}},
        %{name: "blank_defaults", defaults: %{subject: " ", text: ""}},
        %{name: "broken_defaults", defaults: false}
      ]
    end
  end

  @gettext PhoenixKit.Modules.Emails.Gettext

  setup do
    original = Gettext.get_locale(@gettext)
    Gettext.put_locale(@gettext, "en")
    on_exit(fn -> Gettext.put_locale(@gettext, original) end)
    :ok
  end

  defp write!(root, path, content \\ "x") do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp row(name, status \\ "active") do
    n = System.unique_integer([:positive])

    {:ok, template} =
      Templates.create_template(%{
        name: name,
        slug: "slug-#{n}",
        display_name: %{"en" => "Row #{n}"},
        subject: %{"en" => "Subject"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: status
      })

    template
  end

  describe "load/1 — file overrides" do
    @describetag :tmp_dir

    test "a name with a content file under a root is an override", %{tmp_dir: root} do
      write!(root, "welcome/html.html")
      write!(root, "reset/subject.txt")
      write!(root, "notes/markdown.md")
      write!(root, "plain/text.txt")

      assert TemplateSources.load(roots: [root]).overrides ==
               Enum.sort(["welcome", "reset", "notes", "plain"])
    end

    test "a file for another language alone is still an override", %{tmp_dir: root} do
      write!(root, "uk_only/subject.uk.txt")

      assert "uk_only" in TemplateSources.load(roots: [root]).overrides
    end

    test "a directory with only a label or a layout part is not", %{tmp_dir: root} do
      write!(root, "captioned/label.txt")
      write!(root, "grouped/layout.txt")
      File.mkdir_p!(Path.join(root, "empty"))

      assert TemplateSources.load(roots: [root]).overrides == []
    end

    test "every root is read", %{tmp_dir: root} do
      other = Path.join(root, "second")
      write!(root, "one/html.html")
      write!(other, "two/html.html")

      assert TemplateSources.load(roots: [root, other]).overrides == Enum.sort(["one", "two"])
    end

    test "a root that does not exist lists nothing", %{tmp_dir: root} do
      assert TemplateSources.load(roots: [Path.join(root, "nope")]).overrides == []
    end

    test "the roots default to the host's own, as core reads them" do
      assert is_list(Content.override_paths())
      assert is_list(TemplateSources.load().overrides)
    end

    test "a core without the listing API shows nothing", %{tmp_dir: root} do
      write!(root, "welcome/html.html")

      assert TemplateSources.load(roots: [root], overrides: OldOverrides).overrides ==
               []

      assert TemplateSources.load(roots: [root], overrides: Nope.Missing).overrides ==
               []
    end

    test "a root that cannot be read shows nothing and does not crash the page", %{tmp_dir: root} do
      log =
        capture_log(fn ->
          assert TemplateSources.load(roots: [root], overrides: BrokenOverrides).overrides ==
                   []
        end)

      assert log =~ "file overrides"
    end

    test "a core without override_paths/0 shows nothing" do
      assert TemplateSources.load(content: Nope.Missing).overrides == []
    end
  end

  describe "load/1 — defaults" do
    test "core's own emails are defaults, with no owning module" do
      defaults = TemplateSources.load().defaults

      assert Map.fetch!(defaults, "register") == nil
      assert Enum.all?(Catalog.entries(), &Map.has_key?(defaults, &1.name))
    end

    test "a module's email names its module" do
      assert TemplateSources.load(catalog: FakeCatalog).defaults == %{
               "core_mail" => nil,
               "billing_mail" => PhoenixKitBilling
             }
    end

    test "a catalog entry without content defaults is not a shadowed default" do
      assert TemplateSources.load(catalog: CatalogWithoutDefaults).defaults == %{}
    end

    test "a core without the catalog shows nothing" do
      assert TemplateSources.load(catalog: Nope.Missing).defaults == %{}
    end

    test "a catalog that raises shows nothing and does not crash the page" do
      log =
        capture_log(fn -> assert TemplateSources.load(catalog: BrokenCatalog).defaults == %{} end)

      assert log =~ "template default"
    end

    test "a failure in one half does not hide the other", %{} do
      assert TemplateSources.load(catalog: Nope.Missing, overrides: Nope.Missing) ==
               TemplateSources.empty()
    end
  end

  describe "layers/2" do
    setup do
      %{
        sources: %{
          overrides: Enum.sort(["file_mail", "both_mail"]),
          defaults: %{"both_mail" => nil, "billing_mail" => PhoenixKitBilling}
        }
      }
    end

    test "an active row hides a file override", %{sources: sources} do
      assert TemplateSources.layers(row("file_mail"), sources) == [:file]
    end

    test "an active row hides a default, and says whose", %{sources: sources} do
      assert TemplateSources.layers(row("billing_mail"), sources) ==
               [{:default, PhoenixKitBilling}]
    end

    test "both layers are listed, file first", %{sources: sources} do
      assert TemplateSources.layers(row("both_mail"), sources) == [:file, {:default, nil}]
    end

    test "a row with nothing below it hides nothing", %{sources: sources} do
      assert TemplateSources.layers(row("alone_mail"), sources) == []
    end

    test "a row that is not active hides nothing — what is below it is used", %{sources: sources} do
      assert TemplateSources.layers(row("file_mail", "draft"), sources) == []
      assert TemplateSources.layers(row("both_mail", "archived"), sources) == []
    end

    test "the empty sources hide nothing" do
      assert TemplateSources.layers(row("some_mail"), TemplateSources.empty()) == []
    end

    test "something that is not a row hides nothing", %{sources: sources} do
      assert TemplateSources.layers(nil, sources) == []
    end
  end

  describe "the badges" do
    defp badges(template, sources, variant \\ :badge) do
      render_component(&SourceBadges.source_badges/1,
        template: template,
        sources: sources,
        variant: variant
      )
    end

    defp sources(overrides, defaults),
      do: %{overrides: Enum.sort(overrides), defaults: Map.new(defaults)}

    test "nothing is drawn for a row that hides nothing" do
      assert badges(row("clear_mail"), sources(["other"], [])) |> String.trim() == ""
    end

    test "a shadowed file override is named" do
      html = badges(row("file_mail"), sources(["file_mail"], []))

      assert html =~ "File override shadowed"
      assert html =~ "A file override exists for this name — this active row shadows it."
      refute html =~ "default"
    end

    test "a shadowed core default is named" do
      html = badges(row("core_mail"), sources([], [{"core_mail", nil}]))

      assert html =~ "Default shadowed"
      assert html =~ "A built-in default exists for this name — this active row shadows it."
    end

    test "a shadowed module default names the module" do
      html = badges(row("billing_mail"), sources([], [{"billing_mail", PhoenixKitBilling}]))

      assert html =~ "Default shadowed"

      assert html =~
               "A default supplied by PhoenixKitBilling exists for this name — this active row shadows it."
    end

    test "the notice variant spells the sentences out" do
      html =
        badges(row("both_mail"), sources(["both_mail"], [{"both_mail", nil}]), :notice)

      assert html =~ "A file override exists for this name — this active row shadows it."
      assert html =~ "A built-in default exists for this name — this active row shadows it."
      refute html =~ "File override shadowed"
    end

    test "the text is translated" do
      Gettext.put_locale(@gettext, "ru")
      html = badges(row("file_mail"), sources(["file_mail"], []))

      assert html =~ "Файловый оверрайд перекрыт"

      assert html =~
               "Для этого имени есть файловый оверрайд — эта активная строка его перекрывает."

      refute html =~ "File override shadowed"
      refute html =~ "this active row shadows it"
    end

    test "the text is translated into Estonian" do
      Gettext.put_locale(@gettext, "et")
      html = badges(row("file_mail"), sources(["file_mail"], []))

      assert html =~ "Failipõhine ülekirjutus varjatud"
      refute html =~ "File override shadowed"
    end

    test "a badge carries its full text for keyboard and screen-reader users" do
      html = badges(row("file_mail"), sources(["file_mail"], []))

      message = "A file override exists for this name — this active row shadows it."
      assert html =~ ~s(aria-label="#{message}")
      assert html =~ ~s(title="#{message}")
      assert html =~ ~s(tabindex="0")
    end

    test "a file override is a warning, a default only information" do
      file = badges(row("file_mail"), sources(["file_mail"], []))
      default = badges(row("core_mail"), sources([], [{"core_mail", nil}]))

      assert file =~ "badge-warning"
      assert default =~ "badge-info"
      refute default =~ "badge-warning"
    end

    test "the notice stacks its sentences" do
      html = badges(row("both_mail"), sources(["both_mail"], [{"both_mail", nil}]), :notice)

      assert html =~ "alert-vertical"
    end

    test "a template name is not echoed into the markup" do
      html = badges(row("file_mail"), sources(["file_mail"], []))

      refute html =~ "file_mail"
    end

    test "only the last part of a namespaced module's name is shown" do
      html =
        badges(
          row("billing_mail"),
          sources([], [{"billing_mail", Billing}])
        )

      assert html =~ "A default supplied by Billing exists"
      refute html =~ "PhoenixKit.Modules"
    end

    test "a module name is escaped" do
      html = badges(row("m_mail"), sources([], [{"m_mail", :"Elixir.Evil<b>"}]))

      refute html =~ "Evil<b>"
      assert html =~ "Evil&lt;b&gt;"
    end
  end

  describe "the pages" do
    defp editor_assigns(template, sources) do
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
        saving: false,
        template_sources: sources
      }
    end

    defp list_assigns(templates, sources) do
      %{
        templates: templates,
        total_count: length(templates),
        total_pages: 1,
        page: 1,
        per_page: 25,
        stats: %{},
        loading: false,
        show_clone_modal: false,
        clone_template: nil,
        clone_form: %{name: "", display_name: "", errors: %{}},
        confirmation_modal: %{show: false},
        display_locale: "en",
        sort_by: :inserted_at,
        sort_dir: :desc,
        filters: %{search: "", category: "", status: "", is_system: ""},
        template_sources: sources
      }
    end

    defp render_editor(template, sources) do
      render_component(&TemplateEditor.render/1, editor_assigns(template, sources),
        endpoint: PhoenixKitEmails.Test.StubEndpoint
      )
    end

    defp render_list(templates, sources) do
      render_component(&TemplatesLive.render/1, list_assigns(templates, sources),
        endpoint: PhoenixKitEmails.Test.StubEndpoint
      )
    end

    test "the editor says an active row shadows a file" do
      template = row("file_mail")

      html = render_editor(template, sources(["file_mail"], [{"file_mail", nil}]))

      assert html =~ "A file override exists for this name — this active row shadows it."
      assert html =~ "A built-in default exists for this name — this active row shadows it."
    end

    test "the editor is quiet for a row that hides nothing" do
      html = render_editor(row("clear_mail"), sources(["other"], [{"other", nil}]))

      refute html =~ "this active row shadows it"
    end

    test "the editor is quiet for a draft, even with a file under it" do
      html = render_editor(row("file_mail", "draft"), sources(["file_mail"], []))

      refute html =~ "this active row shadows it"
    end

    test "the editor of a template that is not saved yet has no badges" do
      assigns =
        %Template{}
        |> editor_assigns(sources(["new_mail"], []))
        |> Map.merge(%{mode: :new, template: nil})

      html =
        render_component(&TemplateEditor.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      refute html =~ "this active row shadows it"
    end

    test "the list marks the row, in the table and in the cards" do
      shadowing = row("file_mail")
      alone = row("clear_mail")

      html = render_list([shadowing, alone], sources(["file_mail"], []))

      # Table row + card header each carry the badge, for the one row only.
      assert length(String.split(html, "File override shadowed")) - 1 == 2
    end

    test "the list is unchanged where no layer is hidden" do
      html = render_list([row("clear_mail")], TemplateSources.empty())

      refute html =~ "shadowed"
    end

    test "an editor rendered without sources assigned still renders" do
      template = row("file_mail")
      assigns = template |> editor_assigns(nil) |> Map.delete(:template_sources)

      html =
        render_component(&TemplateEditor.render/1, assigns,
          endpoint: PhoenixKitEmails.Test.StubEndpoint
        )

      refute html =~ "this active row shadows it"
    end

    test "mounting the pages starts from no sources" do
      assert {:ok, list} = TemplatesLive.mount(%{}, %{}, bare_socket())
      assert list.assigns.template_sources == TemplateSources.empty()

      assert {:ok, editor} = TemplateEditor.mount(%{}, %{}, bare_socket())
      assert editor.assigns.template_sources == TemplateSources.empty()
    end

    test "opening the list loads the sources, once" do
      assert {:ok, socket} = TemplatesLive.mount(%{}, %{}, bare_socket(%{stats: %{}}))
      refute socket.assigns.template_sources_loaded

      assert {:noreply, socket} = TemplatesLive.handle_params(%{}, "http://x/", socket)
      assert socket.assigns.template_sources_loaded
      refute socket.assigns.template_sources == TemplateSources.empty()
      assert Map.has_key?(socket.assigns.template_sources.defaults, "register")

      # A later patch (filter, page) does not read the layers again.
      kept = %{overrides: ["kept"], defaults: %{}}
      socket = Phoenix.Component.assign(socket, :template_sources, kept)
      assert {:noreply, socket} = TemplatesLive.handle_params(%{}, "http://x/", socket)
      assert socket.assigns.template_sources == kept

      # Refresh does.
      assert {:noreply, socket} = TemplatesLive.handle_event("refresh", %{}, socket)
      refute socket.assigns.template_sources == kept
    end

    test "opening the editor for a row loads the sources" do
      template = row("welcome_back")

      socket = bare_socket(%{current_editor_locale: "en", available_locales: ["en"]})

      assert {:noreply, socket} =
               TemplateEditor.handle_params(%{"id" => template.uuid}, "http://x/", socket)

      assert %{overrides: overrides, defaults: defaults} = socket.assigns.template_sources
      assert is_list(overrides)
      assert is_map(defaults)
    end
  end

  defp bare_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns),
      private: %{live_temp: %{}}
    }
  end
end
