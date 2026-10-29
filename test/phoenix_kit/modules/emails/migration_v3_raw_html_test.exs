defmodule PhoenixKit.Modules.Emails.MigrationV3RawHtmlTest do
  @moduledoc """
  V3 rewrites `{{name}}` to `{{{name}}}` in stored `html_body` values, for
  every name on `Template.raw_html_variables/0`. Since #43, `{{name}}` is
  HTML-escaped in `html_body`; without this step a billing row written
  before then would mail its line-item table as escaped text.

  The statements are run against real rows here: the rewrite is a Postgres
  regular expression, and a pure test of the SQL string would prove nothing
  about what it does to the data.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.Migrations
  alias PhoenixKitEmails.Test.LegacyTemplates
  alias PhoenixKitEmails.Test.Repo

  setup do
    LegacyTemplates.create_table!()
    :ok
  end

  defp up_rewrite, do: Enum.filter(Migrations.up_statements("public", 3), &rewrite?/1)
  defp down_rewrite, do: Enum.filter(Migrations.down_statements("public", 2), &rewrite?/1)

  defp rewrite?(statement), do: statement =~ ~r/\bUPDATE .*phoenix_kit_email_templates/s

  defp run(statements) do
    Enum.each(statements, &Repo.query!/1)
  end

  defp insert(name, html_body, opts \\ []) do
    text_body = Keyword.get(opts, :text_body, %{"en" => "{{line_items_html}}"})

    %{rows: [[uuid]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_email_templates
          (name, slug, display_name, subject, html_body, text_body, inserted_at, updated_at)
        VALUES ($1, $1, '{"en": "T"}', '{"en": "{{line_items_html}}"}', $2, $3, now(), now())
        RETURNING uuid
        """,
        [name, html_body, text_body]
      )

    uuid
  end

  defp row(uuid) do
    %{rows: [[subject, html_body, text_body]]} =
      Repo.query!(
        "SELECT subject, html_body, text_body FROM phoenix_kit_email_templates WHERE uuid = $1",
        [uuid]
      )

    %{subject: subject, html_body: html_body, text_body: text_body}
  end

  test "on a database without the table the step does nothing and does not fail" do
    Repo.query!("DROP TABLE phoenix_kit_email_templates")
    assert :ok = run(up_rewrite())
    assert :ok = run(down_rewrite())
  end

  test "V3 carries exactly one rewrite statement, and V2 none" do
    assert length(up_rewrite()) == 1
    refute Enum.any?(Migrations.up_statements("public", 2), &rewrite?/1)
  end

  test "every locale of html_body is rewritten, other fields are not" do
    uuid =
      insert("v3_locales", %{
        "en" => "<tbody>{{line_items_html}}</tbody>",
        "uk" => "<tbody>{{ line_items_html }}</tbody>"
      })

    run(up_rewrite())

    assert row(uuid).html_body == %{
             "en" => "<tbody>{{{line_items_html}}}</tbody>",
             "uk" => "<tbody>{{{line_items_html}}}</tbody>"
           }

    assert row(uuid).subject == %{"en" => "{{line_items_html}}"}
    assert row(uuid).text_body == %{"en" => "{{line_items_html}}"}
  end

  test "every raw-HTML name is covered, including line_items_table_html" do
    uuid =
      insert("v3_names", %{
        "en" => "{{line_items_html}} {{line_items_table_html}} {{user_name}} {{items_html}}"
      })

    run(up_rewrite())

    assert row(uuid).html_body == %{
             "en" =>
               "{{{line_items_html}}} {{{line_items_table_html}}} {{user_name}} {{items_html}}"
           }
  end

  test "adjacent and repeated placeholders are all rewritten" do
    uuid =
      insert("v3_adjacent", %{
        "en" => "{{line_items_html}}{{line_items_html}}\n{{line_items_html}}"
      })

    run(up_rewrite())

    assert row(uuid).html_body == %{
             "en" => "{{{line_items_html}}}{{{line_items_html}}}\n{{{line_items_html}}}"
           }
  end

  test "it is idempotent: already-raw placeholders are left alone, and a second run changes nothing" do
    uuid =
      insert("v3_idempotent", %{
        "en" => "{{{line_items_html}}} {{{ line_items_html }}} {{line_items_html}}"
      })

    run(up_rewrite())
    once = row(uuid)
    run(up_rewrite())

    assert row(uuid) == once

    assert once.html_body == %{
             "en" => "{{{line_items_html}}} {{{ line_items_html }}} {{{line_items_html}}}"
           }
  end

  test "brace runs that are not a plain double placeholder are left alone" do
    content =
      "{{{{line_items_html}}}} {{{line_items_html}} {{line_items_html}}} {{line_items_htmlx}} {{xline_items_html}}"

    uuid = insert("v3_odd", %{"en" => content})

    run(up_rewrite())

    assert row(uuid).html_body == %{"en" => content}
  end

  test "a row whose html_body is not a locale map, or holds a non-string, does not stop the step" do
    scalar = insert("v3_scalar", "{{line_items_html}}")
    mixed = insert("v3_mixed", %{"en" => "{{line_items_html}}", "meta" => 1})

    run(up_rewrite())

    assert row(scalar).html_body == "{{line_items_html}}"
    assert row(mixed).html_body == %{"en" => "{{{line_items_html}}}", "meta" => 1}
  end

  test "the whitespace a placeholder may carry is the renderer's, not Postgres' own" do
    # Same characters the renderer's \s reads: space, tab, CR, LF, FF, VT.
    ascii = "{{ \t\r\n\f\vline_items_html \v\f\n\r\t }}"
    # Postgres' \s would also take these (EM SPACE under a UTF-8 locale); the
    # renderer does not, so the row means "no placeholder here" to it and the
    # migration must not turn it into one.
    unicode = "{{\u2003line_items_html}}"

    uuid = insert("v3_ws", %{"en" => ascii <> "|" <> unicode})
    run(up_rewrite())

    assert row(uuid).html_body == %{
             "en" => "{{{line_items_html}}}|" <> unicode
           }
  end

  test "the names are frozen in the migration, not read from Template.raw_html_variables/0" do
    # Adding a name to that list later must not make an already-shipped V3
    # rewrite more than it did on release day. Behaviourally the two are the
    # same today, so the pin is the statement itself, and the source.
    assert [statement] = up_rewrite()
    assert statement =~ "(line_items_html|line_items_table_html)"

    source = File.read!(Path.join([File.cwd!(), "lib/phoenix_kit/modules/emails/migrations.ex"]))
    refute source =~ ~r/Template\.raw_html_variables\(\)/
  end

  test "rolling back below V3 restores double braces for older code" do
    uuid =
      insert("v3_down", %{"en" => "{{line_items_html}} {{{ line_items_table_html }}} {{{other}}}"})

    run(up_rewrite())
    run(down_rewrite())

    assert row(uuid).html_body == %{
             "en" => "{{line_items_html}} {{line_items_table_html}} {{{other}}}"
           }

    assert length(down_rewrite()) == 1
    refute Enum.any?(Migrations.down_statements("public", 3), &rewrite?/1)
  end
end
