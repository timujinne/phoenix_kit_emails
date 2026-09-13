defmodule PhoenixKit.Modules.Emails.TemplateExportDBTest do
  @moduledoc """
  The classification against rows that have actually round-tripped through
  JSONB — the link the struct-level tests cannot cover.
  """
  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates

  test "a seeded row loaded back from the database is not reported as edited" do
    # If JSONB decoding produced maps that compared unequal to the shipped
    # defaults, every install would export every template and an operator's
    # real edits would be buried in noise. This is the only place that link is
    # exercised.
    {:ok, _seeded} = Templates.seed_system_templates()

    shipped = Templates.default_system_templates()
    stored = Templates.list_templates(%{is_system: true})

    assert stored != [], "expected the seed to have inserted rows"

    plan = TemplateExport.plan(stored, shipped)

    assert plan.edited == [],
           "freshly seeded rows reported as edited: " <>
             Enum.map_join(plan.edited, ", ", & &1.name)

    assert plan.files == []
  end

  @tag :tmp_dir
  test "an edited row exports files whose content is the operator's", %{tmp_dir: dir} do
    {:ok, _} = Templates.seed_system_templates()

    template = Templates.get_template_by_name("register")
    {:ok, _} = Templates.update_template(template, %{subject: %{"en" => "Please confirm"}})

    plan =
      TemplateExport.plan(
        Templates.list_templates(%{is_system: true}),
        Templates.default_system_templates(),
        out: dir
      )

    assert [%{name: "register"}] = plan.edited

    TemplateExport.write_files(plan.files)

    assert File.read!(Path.join([dir, "register", "subject.txt"])) == "Please confirm"
  end
end
