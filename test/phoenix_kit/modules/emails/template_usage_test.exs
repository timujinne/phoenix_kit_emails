defmodule PhoenixKit.Modules.Emails.TemplateUsageTest.FailingAdapter do
  @moduledoc false
  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :relay_down}
end

defmodule PhoenixKit.Modules.Emails.TemplateUsageTest do
  @moduledoc """
  A template's `usage_count` and `last_used_at` (#49):

    * the count is raised in the database (`usage_count = usage_count + 1`),
      not written back from the struct the caller happens to hold, so sends
      that overlap each count;
    * a send is counted when the message was delivered — an error, or a
      message the transport only logged, is not a use.
  """

  use PhoenixKitEmails.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Emails.Provider
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKitEmails.Test.Repo

  defp create! do
    n = System.unique_integer([:positive])

    {:ok, template} =
      Templates.create_template(%{
        name: "usage_#{n}",
        slug: "usage-#{n}",
        display_name: %{"en" => "Usage #{n}"},
        subject: %{"en" => "Subject"},
        html_body: %{"en" => "<p>Hi</p>"},
        text_body: %{"en" => "Hi"},
        category: "transactional",
        status: "active"
      })

    template
  end

  defp stored(template), do: Repo.get!(Template, template.uuid)

  # Points the core mailer at `adapter` for the duration of one test.
  defp use_mail_adapter(adapter) do
    previous = Application.get_env(:phoenix_kit, PhoenixKit.Mailer)
    Application.put_env(:phoenix_kit, PhoenixKit.Mailer, adapter: adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, PhoenixKit.Mailer, previous),
        else: Application.delete_env(:phoenix_kit, PhoenixKit.Mailer)
    end)
  end

  describe "Templates.track_usage/1" do
    test "raises the count by one, stamps last_used_at and returns the stored row" do
      template = create!()
      assert template.usage_count == 0
      assert template.last_used_at == nil

      assert {:ok, %Template{} = used} = Templates.track_usage(template)

      assert used.usage_count == 1
      assert %DateTime{} = used.last_used_at
      assert used.name == template.name
      assert stored(template).usage_count == 1
      assert stored(template).last_used_at == used.last_used_at
    end

    test "counts from the stored value, not from the struct it was given" do
      # Two sends resolved the template before either counted: both hold
      # usage_count 0. Writing `0 + 1` back twice would leave 1.
      template = create!()

      assert {:ok, _} = Templates.track_usage(template)
      assert {:ok, used} = Templates.track_usage(template)

      assert used.usage_count == 2
      assert stored(template).usage_count == 2
    end

    test "overlapping calls all count" do
      template = create!()

      1..12
      |> Enum.map(fn _ -> Task.async(fn -> Templates.track_usage(template) end) end)
      |> Task.await_many(10_000)
      |> Enum.each(&assert({:ok, _} = &1))

      assert stored(template).usage_count == 12
    end

    test "changes the usage columns and nothing else" do
      template = create!()
      hour_ago = DateTime.add(template.updated_at, -3600)

      {1, _} =
        Repo.update_all(from(t in Template, where: t.uuid == ^template.uuid),
          set: [updated_at: hour_ago]
        )

      template = stored(template)
      assert template.updated_at == hour_ago

      assert {:ok, _} = Templates.track_usage(template)

      after_use = stored(template)

      assert Map.drop(after_use, [:usage_count, :last_used_at]) ==
               Map.drop(template, [:usage_count, :last_used_at])
    end

    test "a template that is gone is an error, not a crash" do
      template = create!()
      {:ok, _} = Templates.delete_template(template)

      assert {:error, :not_found} = Templates.track_usage(template)
    end

    test "another template's count is untouched" do
      used = create!()
      other = create!()

      assert {:ok, _} = Templates.track_usage(used)

      assert stored(other).usage_count == 0
      assert stored(other).last_used_at == nil
    end
  end

  describe "Provider.track_usage/1 (the PhoenixKit.Email.Provider callback)" do
    test "counts the use and answers :ok, as the callback declares" do
      template = create!()

      assert Provider.track_usage(template) == :ok
      assert stored(template).usage_count == 1
    end

    test "answers :ok, and logs, when the template is gone" do
      template = create!()
      {:ok, _} = Templates.delete_template(template)

      log = capture_log(fn -> assert Provider.track_usage(template) == :ok end)

      assert log =~ "Could not count a use of template #{template.name}"
    end
  end

  describe "Provider.count_use_if_delivered/2" do
    test "a delivered message counts, and the result is passed through" do
      template = create!()
      result = {:ok, %{id: "msg-1"}}

      assert Provider.count_use_if_delivered(result, template) == result
      assert stored(template).usage_count == 1
    end

    test "a failed delivery is not a use" do
      template = create!()

      for result <- [{:error, :blocked}, {:error, %{reason: "relay down"}}, {:error, "x"}] do
        assert Provider.count_use_if_delivered(result, template) == result
      end

      assert stored(template).usage_count == 0
      assert stored(template).last_used_at == nil
    end

    test "a test send whose delivery fails is not a use" do
      use_mail_adapter(PhoenixKit.Modules.Emails.TemplateUsageTest.FailingAdapter)
      Templates.seed_system_templates()
      template = Templates.get_active_template_by_name("test_email")

      capture_log(fn ->
        assert {:error, _} = Provider.send_test_tracking_email("probe@example.com", nil)
      end)

      assert stored(template).usage_count == 0
      assert stored(template).last_used_at == nil
    end

    test "a delivered test send counts the template once" do
      use_mail_adapter(Swoosh.Adapters.Test)
      Templates.seed_system_templates()
      template = Templates.get_active_template_by_name("test_email")
      assert template.usage_count == 0

      assert {:ok, _} = Provider.send_test_tracking_email("probe@example.com", nil)

      assert_received {:email, %Swoosh.Email{}}
      assert stored(template).usage_count == 1
      assert %DateTime{} = stored(template).last_used_at
    end

    test "a message the transport only logged is not a use" do
      template = create!()
      result = {:ok, %{id: "dev-mailbox-suppressed", suppressed: true}}

      assert Provider.count_use_if_delivered(result, template) == result
      assert stored(template).usage_count == 0
    end

    test "a counting failure does not change what the caller is told about the delivery" do
      template = create!()
      {:ok, _} = Templates.delete_template(template)
      result = {:ok, %{id: "msg-2"}}

      log =
        capture_log(fn ->
          assert Provider.count_use_if_delivered(result, template) == result
        end)

      assert log =~ "Could not count a use of template #{template.name}"
    end

    test "a count that raises does not change what the caller is told about the delivery" do
      # A uuid that is not a uuid makes the UPDATE raise instead of answering
      # {:error, _}.
      template = %{create!() | uuid: "not-a-uuid"}
      result = {:ok, %{id: "msg-3"}}

      log =
        capture_log(fn ->
          assert Provider.count_use_if_delivered(result, template) == result
        end)

      assert log =~ "Could not count a use of template #{template.name}"
    end
  end
end
