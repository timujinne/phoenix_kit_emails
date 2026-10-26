defmodule PhoenixKit.Modules.Emails.LogTemplateSourceTest do
  @moduledoc """
  The log remembers which layer built the message (#48): `template_uuid` and
  `template_source` (`"db"` / `"file"` / `"module"`, `nil` without a template).
  Core's `send_from_template` passes `:template_uuid` when an active database
  row was used; the notification mails pass only `:template_name`, so the layer
  is derived here from direct evidence.
  """

  use PhoenixKitEmails.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]
  import Swoosh.Email, except: [from: 2]

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.ApplicationIntegration
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.Provider
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.TemplateSources
  alias PhoenixKit.Modules.Emails.Web.Details
  alias PhoenixKit.Modules.Emails.Web.SourceBadges
  alias PhoenixKit.Modules.Emails.Web.TemplateEditor
  alias PhoenixKit.Templates.Overrides
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKitEmails.Test.Repo

  defmodule FakeCatalog do
    def entries do
      [
        %{name: "module_mail", defaults: %{text: "Hello"}},
        %{name: "no_defaults_mail", defaults: %{}}
      ]
    end
  end

  defmodule BrokenCatalog do
    def entries, do: raise("a catalog entry blew up")
  end

  defmodule BrokenLocate do
    def locate(_roots, _name, _part, _locale), do: raise("unreadable root")
  end

  setup do
    {:ok, _} = Emails.enable_system()
    # Every answer here depends on which rows exist, and "magic_link" is used as
    # "a core default with no row": a row committed to the test database outside
    # the sandbox would turn it into "db". Rolled back with the sandbox.
    Repo.delete_all(Template)
    :ok
  end

  defp email do
    new()
    |> to("recipient@example.com")
    |> Swoosh.Email.from("sender@example.com")
    |> subject("Hello")
    |> text_body("Hi")
  end

  defp log_for(opts) do
    {:ok, log} = Interceptor.create_email_log(email(), opts)
    Repo.reload!(log)
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

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # Override files for `name`, in a root core's `override_paths/0` will return.
  defp with_root(tmp_dir) do
    previous = Application.get_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [tmp_dir])
    Overrides.reset_cache([tmp_dir])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :template_paths, previous),
        else: Application.delete_env(:phoenix_kit, :template_paths)

      Overrides.reset_cache([tmp_dir])
    end)

    tmp_dir
  end

  defp write_file(root, name, locale, text \\ "From a file") do
    {:ok, _} = Overrides.write(root, name, :text, locale, text)
    :ok
  end

  describe "TemplateSources.origin/3" do
    test "a valid uuid is the row, whatever else exists for the name" do
      uuid = Ecto.UUID.generate()
      assert TemplateSources.origin(unique("any"), uuid) == {"db", uuid}
    end

    test "an active row with the name is the row, with its uuid" do
      template = row(unique("row_mail"))
      assert TemplateSources.origin(template.name, nil) == {"db", template.uuid}
    end

    test "a draft row is not what a send used" do
      template = row(unique("draft_mail"), "draft")
      assert TemplateSources.origin(template.name, nil, roots: []) == {nil, nil}
    end

    @tag :tmp_dir
    test "a file counts only for the locale it was found for", %{tmp_dir: tmp_dir} do
      name = unique("file_mail")
      write_file(tmp_dir, name, "ru")

      assert TemplateSources.origin(name, nil, roots: [tmp_dir], locale: "ru") == {"file", nil}
      assert TemplateSources.origin(name, nil, roots: [tmp_dir], locale: "en") == {nil, nil}
    end

    @tag :tmp_dir
    test "a locale-less file serves every locale", %{tmp_dir: tmp_dir} do
      name = unique("file_mail")
      write_file(tmp_dir, name, nil)

      assert TemplateSources.origin(name, nil, roots: [tmp_dir], locale: "et") == {"file", nil}
    end

    @tag :tmp_dir
    test "an empty file is no file", %{tmp_dir: tmp_dir} do
      name = unique("file_mail")
      write_file(tmp_dir, name, nil, "  \n")

      assert TemplateSources.origin(name, nil, roots: [tmp_dir]) == {nil, nil}
    end

    @tag :tmp_dir
    test "a row and a file of one name, no uuid: the row wins", %{tmp_dir: tmp_dir} do
      template = row(unique("both_mail"))
      write_file(tmp_dir, template.name, nil)

      assert TemplateSources.origin(template.name, nil, roots: [tmp_dir]) ==
               {"db", template.uuid}
    end

    @tag :tmp_dir
    test "a file and a catalog default of one name: the file wins", %{tmp_dir: tmp_dir} do
      write_file(tmp_dir, "module_mail", nil)

      assert TemplateSources.origin("module_mail", nil, roots: [tmp_dir], catalog: FakeCatalog) ==
               {"file", nil}
    end

    test "a name in the catalog of defaults is the module's" do
      assert TemplateSources.origin("module_mail", nil, roots: [], catalog: FakeCatalog) ==
               {"module", nil}
    end

    test "a name nothing resolves has no source" do
      assert TemplateSources.origin("unknown_mail", nil, roots: [], catalog: FakeCatalog) ==
               {nil, nil}

      assert TemplateSources.origin("no_defaults_mail", nil, roots: [], catalog: FakeCatalog) ==
               {nil, nil}
    end

    test "cast_uuid takes only the 36-character form" do
      uuid = Ecto.UUID.generate()
      assert TemplateSources.cast_uuid(uuid) == uuid
      assert TemplateSources.cast_uuid(String.upcase(uuid)) == uuid
      assert TemplateSources.cast_uuid(Ecto.UUID.dump!(uuid)) == nil
      assert TemplateSources.cast_uuid("sixteen byte str") == nil
      assert TemplateSources.cast_uuid(nil) == nil
    end

    test "no name, no source" do
      assert TemplateSources.origin(nil, nil) == {nil, nil}
      assert TemplateSources.origin("", nil) == {nil, nil}
      assert TemplateSources.origin(123, nil) == {nil, nil}
    end

    test "a source that blows up answers nothing instead of raising" do
      assert TemplateSources.origin("x_mail", nil, roots: [], catalog: BrokenCatalog) ==
               {nil, nil}

      assert TemplateSources.origin("x_mail", nil, roots: ["/"], overrides: BrokenLocate) ==
               {nil, nil}
    end
  end

  describe "the interceptor stamps the log" do
    test "an active row named by uuid: db" do
      uuid = Ecto.UUID.generate()
      log = log_for(template_name: "row_mail", template_uuid: uuid)

      assert log.template_name == "row_mail"
      assert log.template_uuid == uuid
      assert log.template_source == "db"
    end

    test "a notification that resolved a row but passed no uuid is still db" do
      template = row(unique("magic_like"))
      log = log_for(template_name: template.name)

      assert log.template_uuid == template.uuid
      assert log.template_source == "db"
    end

    @tag :tmp_dir
    test "a host file override: file, no uuid", %{tmp_dir: tmp_dir} do
      name = unique("file_mail")
      write_file(with_root(tmp_dir), name, nil)
      log = log_for(template_name: name)

      assert log.template_uuid == nil
      assert log.template_source == "file"
    end

    @tag :tmp_dir
    test "a file for another locale than the message's is not file", %{tmp_dir: tmp_dir} do
      name = unique("file_mail")
      write_file(with_root(tmp_dir), name, "ru")

      assert log_for(template_name: name, locale: "en").template_source == nil
      assert log_for(template_name: name, locale: "ru").template_source == "file"
    end

    test "a default shipped by core: module, no uuid" do
      log = log_for(template_name: "magic_link")

      assert log.template_uuid == nil
      assert log.template_source == "module"
    end

    test "a name nothing resolves has no source" do
      log = log_for(template_name: unique("no_such_mail"))

      assert log.template_name != nil
      assert log.template_source == nil
    end

    test "no template: both stay nil" do
      log = log_for([])

      assert log.template_name == nil
      assert log.template_uuid == nil
      assert log.template_source == nil
    end

    test "a layer named by the caller wins, and nil means none" do
      assert log_for(template_name: "magic_link", template_source: "file").template_source ==
               "file"

      assert log_for(template_name: "magic_link", template_source: nil).template_source == nil
    end

    test "a file or module layer named by the caller carries no uuid" do
      log =
        log_for(
          template_name: "magic_link",
          template_uuid: Ecto.UUID.generate(),
          template_source: "file"
        )

      assert {log.template_source, log.template_uuid} == {"file", nil}
    end

    # `UserNotifier.deliver_built/1`: every auth mail is logged as
    # "user_notification" and the row it used travels in the private map.
    test "an auth mail carrying its row in the private map is db with that uuid" do
      template = row(unique("auth_row"))

      {:ok, log} =
        email()
        |> put_private(:phoenix_kit_db_template, template)
        |> Interceptor.create_email_log(template_name: "user_notification")

      log = Repo.reload!(log)
      assert {log.template_source, log.template_uuid} == {"db", template.uuid}
    end

    test "an auth mail that built from a file or default has no layer, whatever its name is" do
      # A row under the logged name is not what built this message.
      row("user_notification")

      {:ok, log} =
        email()
        |> put_private(:phoenix_kit_db_template, nil)
        |> Interceptor.create_email_log(template_name: "user_notification")

      log = Repo.reload!(log)
      assert {log.template_source, log.template_uuid} == {nil, nil}
    end

    test "an unknown source from the caller is ignored" do
      assert log_for(template_name: "magic_link", template_source: "bogus").template_source ==
               "module"
    end

    test "a malformed template_uuid is dropped and the log is still written" do
      for bad <- ["not-a-uuid", 123, ""] do
        log = log_for(template_name: "magic_link", template_uuid: bad)

        assert log.template_uuid == nil
        assert log.template_source == "module"
      end
    end

    test "the changeset refuses a source that is not one of the three" do
      changeset =
        Log.changeset(%Log{}, %{
          message_id: "m",
          to: "a@example.com",
          from: "b@example.com",
          template_source: "bogus"
        })

      assert Keyword.has_key?(changeset.errors, :template_source)
    end
  end

  describe "the senders that know their layer say so" do
    defp use_test_mailer do
      previous = Application.get_env(:phoenix_kit, PhoenixKit.Mailer)
      previous_provider = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Test)
      ApplicationIntegration.register()

      {:ok, _} =
        PhoenixKit.Settings.update_setting_with_module(
          "from_email",
          "mail@example.com",
          "email_system"
        )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, PhoenixKit.Mailer, previous),
          else: Application.delete_env(:phoenix_kit, PhoenixKit.Mailer)

        if previous_provider,
          do: Application.put_env(:phoenix_kit, :email_provider, previous_provider),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)
    end

    defp test_send_log do
      use_test_mailer()
      _ = Provider.send_test_tracking_email("recipient@example.com", nil)
      Repo.one!(from(l in Log, where: l.template_name == "test_email"))
    end

    # The editor's "send test" message, as `handle_event("send_test_email")` posts it.
    defp editor_send(name, template, overrides \\ %{}) do
      use_test_mailer()
      recipient = "editor-#{System.unique_integer([:positive])}@example.com"

      data =
        Map.merge(
          %{
            name: name,
            subject: %{"en" => "Subject"},
            html_body: %{"en" => "<p>Hi</p>"},
            text_body: %{"en" => "Hi"}
          },
          overrides
        )

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, template: template},
        private: %{live_temp: %{}}
      }

      assert {:noreply, updated} =
               TemplateEditor.handle_info({:send_test_email, recipient, data, %{}, "en"}, socket)

      assert updated.assigns.flash["info"], "the test send did not go out"
      Repo.one!(from(l in Log, where: l.to == ^recipient))
    end

    test "the admin test send of a stored template is db with its uuid" do
      Templates.seed_system_templates()
      template = Templates.get_active_template_by_name("test_email")
      assert template

      log = test_send_log()
      assert log.template_source == "db"
      assert log.template_uuid == template.uuid
    end

    test "the built-in fallback body of the test send has no layer" do
      Repo.delete_all(from(t in Template, where: t.name == "test_email"))

      log = test_send_log()
      assert log.template_source == nil
      assert log.template_uuid == nil
    end

    test "core's auth builder and mailer preserve the database row as evidence" do
      use_test_mailer()
      template = row("welcome")
      built = UserNotifier.build_welcome(%{email: "auth@example.com"})

      assert built.private.phoenix_kit_db_template.uuid == template.uuid
      assert {:ok, _email} = UserNotifier.deliver_built(built)

      log = Repo.one!(from(l in Log, where: l.to == "auth@example.com"))
      assert log.template_name == "user_notification"
      assert {log.template_source, log.template_uuid} == {"db", template.uuid}
    end

    test "core's default auth mail never borrows a row matching its logging label" do
      use_test_mailer()
      row("user_notification")
      built = UserNotifier.build_welcome(%{email: "auth@example.com"})

      assert built.private.phoenix_kit_db_template == nil
      assert {:ok, _email} = UserNotifier.deliver_built(built)

      log = Repo.one!(from(l in Log, where: l.to == "auth@example.com"))
      assert log.template_name == "user_notification"
      assert {log.template_source, log.template_uuid} == {nil, nil}
    end
  end

  describe "the template editor's test send" do
    test "a saved template is db with its uuid" do
      template = row(unique("editor_mail"))
      log = editor_send(template.name, template)

      assert log.template_source == "db"
      assert log.template_uuid == template.uuid
    end

    for field <- [:subject, :html_body, :text_body] do
      test "unsaved changes to #{field} are not attributed to the stored row" do
        template = row(unique("editor_mail"))

        log =
          editor_send(template.name, template, %{
            unquote(field) => %{"en" => "Unsaved content"}
          })

        assert {log.template_source, log.template_uuid} == {nil, nil}
        assert Templates.get_template(template.uuid) == template
      end
    end

    test "an unsaved template named like an active row has no layer" do
      template = row(unique("editor_mail"))
      log = editor_send(template.name, nil)

      assert log.template_source == nil
      assert log.template_uuid == nil
    end

    test "an unsaved template with a fresh name has no layer" do
      log = editor_send(unique("editor_new"), nil)

      assert log.template_source == nil
      assert log.template_uuid == nil
    end
  end

  describe "the details page" do
    defp bare_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}}
      }
    end

    defp details_html(log) do
      {:ok, socket} = Details.mount(%{"id" => log.uuid}, %{}, bare_socket())

      assigns =
        Map.merge(socket.assigns, %{
          phoenix_kit_current_scope: nil,
          current_locale: "en",
          url_path: "/admin/emails/#{log.uuid}"
        })

      assigns |> Details.render() |> rendered_to_string()
    end

    test "a log built from a stored row shows the badge and a link to it" do
      template = row(unique("details_row"))
      log = log_for(template_name: template.name)
      html = details_html(log)

      assert html =~ "Database template"
      assert html =~ "/admin/emails/templates/#{template.uuid}/edit"
    end

    test "the link is gone with the row" do
      template = row(unique("details_row"))
      log = log_for(template_name: template.name)
      Repo.delete!(template)
      html = details_html(log)

      assert html =~ "Database template"
      refute html =~ "/edit"
    end

    test "a default shows its own badge" do
      assert details_html(log_for(template_name: "magic_link")) =~ "Default template"
    end
  end

  describe "the details badge" do
    defp badge(attrs) do
      render_component(
        &SourceBadges.log_source/1,
        log: struct(Log, attrs),
        template_exists?: false
      )
    end

    test "db: a badge and a link to the row" do
      uuid = Ecto.UUID.generate()

      html =
        render_component(&SourceBadges.log_source/1,
          log: %Log{template_name: "row_mail", template_source: "db", template_uuid: uuid},
          template_exists?: true
        )

      assert html =~ "Database template"
      assert html =~ "/admin/emails/templates/#{uuid}/edit"
    end

    test "db: no link once the row is gone" do
      html =
        badge(
          template_name: "row_mail",
          template_source: "db",
          template_uuid: Ecto.UUID.generate()
        )

      assert html =~ "Database template"
      refute html =~ "/edit"
    end

    test "file and module get their own badge and no link" do
      assert badge(template_name: "x", template_source: "file") =~ "File override"
      assert badge(template_name: "x", template_source: "module") =~ "Default template"
      refute badge(template_name: "x", template_source: "file") =~ "<a "
    end

    test "nothing for a log without a source" do
      assert badge(template_name: nil, template_source: nil) |> String.trim() == ""
    end
  end
end
