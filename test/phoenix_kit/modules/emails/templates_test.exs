defmodule PhoenixKit.Modules.Emails.TemplatesTest do
  @moduledoc """
  Context-level coverage for the reserved-name guard: `create_template/1`
  must reject a reserved name without `is_system: true`, a crafted
  `is_system: true` in attrs must not bypass that (create_template/1 never
  trusts it — see `Template.changeset/2,3`), the legitimate path
  (`seed_system_templates/0`, which calls the trusted `changeset/3` path)
  must keep working, and `delete_template/1` must still refuse a system row.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKitEmails.Test.Repo

  defp valid_custom_attrs(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        name: "custom_#{n}",
        slug: "custom-#{n}",
        display_name: %{"en" => "Custom #{n}"},
        subject: %{"en" => "Subject"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: "active"
      },
      overrides
    )
  end

  describe "create_template/1 reserved name guard" do
    test "rejects an unseeded reserved name without is_system: true" do
      assert {:error, changeset} =
               Templates.create_template(%{
                 name: "new_login_alert",
                 slug: "new-login-alert",
                 display_name: %{"en" => "New Login Alert"},
                 subject: %{"en" => "New login detected"},
                 html_body: %{"en" => "<p>Hi</p>"},
                 text_body: %{"en" => "Hi"},
                 category: "system",
                 status: "active"
               })

      assert {msg, _} = Keyword.get(changeset.errors, :name)
      assert msg =~ "reserved"
      assert Templates.get_template_by_name("new_login_alert") == nil
    end

    test "a crafted is_system: true in attrs does not bypass the guard" do
      assert {:error, changeset} =
               Templates.create_template(
                 valid_custom_attrs(%{name: "new_login_alert", is_system: true})
               )

      assert {msg, _} = Keyword.get(changeset.errors, :name)
      assert msg =~ "reserved"
      assert Templates.get_template_by_name("new_login_alert") == nil
    end
  end

  describe "update_template/2 reserved name guard" do
    test "a crafted is_system: true does not let a rename into a reserved name through" do
      {:ok, custom} = Templates.create_template(valid_custom_attrs())

      assert {:error, changeset} =
               Templates.update_template(custom, %{
                 name: "failed_login_alert",
                 is_system: true
               })

      assert {msg, _} = Keyword.get(changeset.errors, :name)
      assert msg =~ "reserved"
      assert Templates.get_template(custom.uuid).name == custom.name
      refute Templates.get_template(custom.uuid).is_system
    end

    test "archiving a pre-existing hijack row (reserved name, is_system: false) still works" do
      # A non-system row sitting on a reserved name can only exist if it was
      # written before this guard shipped (or by some other gap) — simulate
      # that with a raw insert that bypasses Template.changeset/2 entirely,
      # then confirm it can still be remediated (archived) afterward.
      hijack =
        %Template{}
        |> Ecto.Changeset.change(
          Map.put(valid_custom_attrs(%{name: "new_login_alert"}), :is_system, false)
        )
        |> Repo.insert!()

      assert {:ok, archived} = Templates.archive_template(hijack)
      assert archived.status == "archived"
    end
  end

  describe "seed_system_templates/0" do
    test "still succeeds now that reserved names are guarded" do
      assert {:ok, templates} = Templates.seed_system_templates()

      assert length(templates) == length(Templates.default_system_templates())
      assert Enum.all?(templates, & &1.is_system)
    end
  end

  describe "clone_template/3" do
    test "wraps a plain display_name string into an i18n map" do
      {:ok, source} = Templates.create_template(valid_custom_attrs())
      name = "clone_#{System.unique_integer([:positive])}"

      assert {:ok, clone} = Templates.clone_template(source, name, %{display_name: "Copy"})
      assert clone.display_name == %{"en" => "Copy"}
      assert clone.is_system == false
    end
  end

  describe "delete_template/1" do
    test "rejects a system template (context-level guard, independent of the LiveView one)" do
      {:ok, seeded} = Templates.seed_system_templates()
      system_template = Enum.find(seeded, & &1.is_system)

      assert {:error, :system_template_protected} =
               Templates.delete_template(system_template)

      assert Templates.get_template(system_template.uuid) != nil
    end

    test "a non-system template can still be deleted" do
      {:ok, custom} = Templates.create_template(valid_custom_attrs())

      assert {:ok, %Template{}} = Templates.delete_template(custom)
      assert Templates.get_template(custom.uuid) == nil
    end
  end
end
