defmodule PhoenixKit.Modules.Emails.TemplateChangesetTest do
  @moduledoc """
  What `Template.changeset/3` does with the three things the editor form sends
  that are not plain scalars (#45, #47):

    * a locale the author left empty is not a translation — it is dropped, and
      a template needs at least one locale with text, not one per language;
    * `metadata` is merged into what the row already has, so a form that
      submits only `source_module` cannot erase `cloned_from`, and
      `source_module` is one of `valid_source_modules/0`;
    * the audit columns are never read from attrs — the context sets them.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Template

  @user "01900000-0000-7000-8000-000000000001"
  @other "01900000-0000-7000-8000-000000000002"

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "changeset_case",
        "display_name" => %{"en" => "Case"},
        "subject" => %{"en" => "Subject"},
        "html_body" => %{"en" => "<p>Hi</p>"},
        "text_body" => %{"en" => "Hi"},
        "category" => "transactional",
        "status" => "draft"
      },
      overrides
    )
  end

  defp change(changeset, field), do: Ecto.Changeset.get_change(changeset, field)

  describe "stored_translation/2 (#45)" do
    test "returns exactly what is stored for the locale, with no fallback" do
      map = %{"en" => "Hello", "uk" => "Привіт"}

      assert Template.stored_translation(map, "uk") == "Привіт"
      assert Template.stored_translation(map, "en") == "Hello"
      assert Template.stored_translation(map, "et") == ""
      assert Template.stored_translation(map, "en-US") == ""
    end

    test "is empty for a missing or malformed field" do
      assert Template.stored_translation(nil, "en") == ""
      assert Template.stored_translation(%{}, "en") == ""
      assert Template.stored_translation("plain", "en") == ""
      assert Template.stored_translation(%{"en" => 5}, "en") == ""
    end

    test "a regional tab with no key of its own reads the base key, but only the first such tab" do
      map = %{"en" => "Hello"}

      assert Template.stored_translation(map, "en-US", ["en-US", "et"]) == "Hello"
      assert Template.stored_translation(map, "en-US", ["en-US", "en-GB"]) == "Hello"
      assert Template.stored_translation(map, "en-GB", ["en-US", "en-GB"]) == ""
      assert Template.stored_translation(map, "en-GB", ["et", "en-GB", "en-US"]) == "Hello"
    end

    test "a base code that is a tab of its own is not inherited, and an own key wins" do
      assert Template.stored_translation(%{"en" => "Hello"}, "en-US", ["en", "en-US"]) == ""
      assert Template.stored_translation(%{"en" => "Hello"}, "en-US", ["en-US", "en"]) == ""

      assert Template.stored_translation(%{"en" => "A", "en-US" => "B"}, "en-US", ["en-US"]) ==
               "B"
    end

    test "without tabs the lookup is exact, and unrelated bases are not inherited" do
      assert Template.stored_translation(%{"en" => "Hello"}, "en-US") == ""
      assert Template.stored_translation(%{"en" => "Hello"}, "et", ["et", "en-US"]) == ""
      assert Template.stored_translation(%{"en" => "Hello"}, "en-US", ["en-US"]) == "Hello"
    end

    test "an empty own key is the tab's value; the base key is not read through it" do
      assert Template.stored_translation(%{"en" => "Hello", "en-US" => ""}, "en-US", ["en-US"]) ==
               ""
    end

    test "get_translation/3 keeps falling back — rendering still needs it" do
      assert Template.get_translation(%{"en" => "Hello"}, "et") == "Hello"
    end
  end

  describe "empty locales (#45)" do
    test "an empty locale is dropped from every translated field" do
      changeset =
        Template.changeset(
          %Template{},
          attrs(%{
            "display_name" => %{"en" => "Case", "et" => ""},
            "description" => %{"en" => "About", "et" => ""},
            "subject" => %{"en" => "Subject", "et" => "", "ru" => ""},
            "html_body" => %{"en" => "<p>Hi</p>", "et" => ""},
            "text_body" => %{"en" => "Hi", "et" => ""}
          })
        )

      assert changeset.valid?, inspect(changeset.errors)

      assert change(changeset, :display_name) == %{"en" => "Case"}
      assert change(changeset, :description) == %{"en" => "About"}
      assert change(changeset, :subject) == %{"en" => "Subject"}
      assert change(changeset, :html_body) == %{"en" => "<p>Hi</p>"}
      assert change(changeset, :text_body) == %{"en" => "Hi"}
    end

    test "a locale holding only whitespace is empty too" do
      changeset =
        Template.changeset(
          %Template{},
          attrs(%{"subject" => %{"en" => "Subject", "et" => "  \n\t "}})
        )

      assert changeset.valid?
      assert change(changeset, :subject) == %{"en" => "Subject"}
    end

    test "text in a locale is kept exactly as typed, spaces included" do
      changeset =
        Template.changeset(%Template{}, attrs(%{"text_body" => %{"en" => "  indented\n"}}))

      assert change(changeset, :text_body) == %{"en" => "  indented\n"}
    end

    test "a template in one language is valid when other languages are enabled" do
      # The editor posts a key per enabled locale; the one tab the author
      # filled in is the only one with text.
      changeset =
        Template.changeset(
          %Template{},
          attrs(%{
            "display_name" => %{"en" => "", "et" => "Tere"},
            "subject" => %{"en" => "", "et" => "Tere"},
            "html_body" => %{"en" => "", "et" => "<p>Tere</p>"},
            "text_body" => %{"en" => "", "et" => "Tere"}
          })
        )

      assert changeset.valid?, inspect(changeset.errors)
      assert change(changeset, :subject) == %{"et" => "Tere"}
    end

    for field <- [:display_name, :subject, :html_body, :text_body] do
      test "#{field} with no text in any locale is an error" do
        changeset =
          Template.changeset(
            %Template{},
            attrs(%{"#{unquote(field)}" => %{"en" => "", "et" => " "}})
          )

        refute changeset.valid?
        assert {msg, _} = Keyword.fetch!(changeset.errors, unquote(field))
        assert msg =~ "at least one"
      end
    end

    test "an optional description may be empty in every locale" do
      changeset = Template.changeset(%Template{}, attrs(%{"description" => %{"en" => ""}}))

      assert changeset.valid?
      assert change(changeset, :description) == %{}
    end

    test "an optional description still requires text values" do
      for value <- [nil, false, 5, [], %{}] do
        changeset = Template.changeset(%Template{}, attrs(%{"description" => %{"en" => value}}))
        refute changeset.valid?
        assert {message, _} = Keyword.fetch!(changeset.errors, :description)
        assert message =~ "must be a string"
      end
    end

    test "a value that is not a string is still reported, not dropped" do
      changeset = Template.changeset(%Template{}, attrs(%{"subject" => %{"en" => 5}}))

      refute changeset.valid?
      assert {msg, _} = Keyword.fetch!(changeset.errors, :subject)
      assert msg =~ "must be a string"
    end

    test "per-locale length limits still apply to the text that is there" do
      changeset =
        Template.changeset(
          %Template{},
          attrs(%{"display_name" => %{"en" => "Case", "et" => "x"}})
        )

      refute changeset.valid?
      assert {msg, _} = Keyword.fetch!(changeset.errors, :display_name)
      assert msg =~ "et: must be at least 2"
    end

    test "saving the stored translations back leaves them unchanged" do
      template = %Template{
        name: "round_trip",
        slug: "round-trip",
        display_name: %{"en" => "Case"},
        subject: %{"en" => "Subject"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: "active"
      }

      # What the fixed editor posts for an untranslated et/ru: nothing but
      # empty strings, which must not appear as keys afterwards.
      changeset =
        Template.changeset(
          template,
          %{
            "subject" => %{"en" => "Subject", "et" => "", "ru" => ""},
            "html_body" => %{"en" => "<p>Hi</p>", "et" => "", "ru" => ""}
          }
        )

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).subject == %{"en" => "Subject"}
      assert Ecto.Changeset.apply_changes(changeset).html_body == %{"en" => "<p>Hi</p>"}
    end
  end

  describe "metadata (#47)" do
    defp existing(metadata) do
      %Template{
        name: "meta_case",
        slug: "meta-case",
        display_name: %{"en" => "Case"},
        subject: %{"en" => "Subject"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: "active",
        metadata: metadata
      }
    end

    test "a submitted source_module is merged into the existing metadata" do
      template = existing(%{"source_module" => "users", "cloned_from" => "abc"})

      changeset = Template.changeset(template, %{"metadata" => %{"source_module" => "billing"}})

      assert changeset.valid?, inspect(changeset.errors)

      assert Ecto.Changeset.apply_changes(changeset).metadata ==
               %{"source_module" => "billing", "cloned_from" => "abc"}
    end

    test "metadata that is not submitted is left alone" do
      template = existing(%{"cloned_from" => "abc"})

      changeset = Template.changeset(template, %{"subject" => %{"en" => "New"}})

      assert change(changeset, :metadata) == nil
      assert Ecto.Changeset.apply_changes(changeset).metadata == %{"cloned_from" => "abc"}
    end

    test "submitting the value the row already has is not a change" do
      template = existing(%{"source_module" => "users", "cloned_from" => "abc"})

      changeset = Template.changeset(template, %{"metadata" => %{"source_module" => "users"}})

      assert change(changeset, :metadata) == nil
    end

    test "atom keys are merged under their string name, not beside it" do
      template = existing(%{"source_module" => "users"})

      changeset = Template.changeset(template, %{metadata: %{source_module: "billing"}})

      assert Ecto.Changeset.apply_changes(changeset).metadata == %{"source_module" => "billing"}
    end

    test "a new template takes the submitted metadata as it is" do
      changeset =
        Template.changeset(%Template{}, attrs(%{"metadata" => %{"source_module" => "billing"}}))

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).metadata == %{"source_module" => "billing"}
    end

    test "source_module must be one of valid_source_modules/0" do
      for bad <- ["evil", "", "USERS", 5, nil, %{"a" => 1}] do
        changeset =
          Template.changeset(
            existing(%{"source_module" => "users"}),
            %{"metadata" => %{"source_module" => bad}}
          )

        refute changeset.valid?, "accepted #{inspect(bad)}"
        assert {msg, _} = Keyword.fetch!(changeset.errors, :metadata)
        assert msg =~ "source_module"
      end
    end

    test "every module on the list is accepted" do
      for source <- Template.valid_source_modules() do
        changeset =
          Template.changeset(existing(%{}), %{"metadata" => %{"source_module" => source}})

        assert changeset.valid?, "rejected #{source}"
      end
    end

    test "other metadata keys are not constrained" do
      changeset =
        Template.changeset(existing(%{}), %{"metadata" => %{"order_uuid" => "x", "n" => 1}})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).metadata == %{"order_uuid" => "x", "n" => 1}
    end
  end

  describe "audit columns (#47)" do
    test "created_by_user_uuid and updated_by_user_uuid are not cast from attrs" do
      for keys <- [
            %{"created_by_user_uuid" => @user, "updated_by_user_uuid" => @other},
            %{created_by_user_uuid: @user, updated_by_user_uuid: @other}
          ] do
        changeset = Template.changeset(%Template{}, Map.merge(attrs(), keys) |> atomize_if(keys))

        assert change(changeset, :created_by_user_uuid) == nil
        assert change(changeset, :updated_by_user_uuid) == nil
      end
    end

    # A map may not mix atom and string keys; the second shape above is
    # all-atom, so the whole attrs map is converted to match.
    defp atomize_if(merged, %{created_by_user_uuid: _}),
      do: Map.new(merged, fn {k, v} -> {String.to_atom(to_string(k)), v} end)

    defp atomize_if(merged, _), do: merged
  end
end
