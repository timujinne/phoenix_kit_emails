defmodule PhoenixKit.Modules.Emails.InterceptorBrevoTest do
  @moduledoc """
  Before this fix, `Interceptor.update_after_send/2` recovered the
  provider's own message id (into `aws_message_id`, for later event
  correlation) only for `provider: "aws_ses"` — a Brevo-sent log's
  `aws_message_id` was left `nil` forever, so `BrevoPollingJob` could
  never match a polled Brevo event back to its `Log` row.
  """

  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKitEmails.Test.Repo

  defp create_brevo_log do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "brevo_api",
        status: "queued"
      })
      |> Repo.insert()

    log
  end

  test "extracts Brevo's own message id from a %{id: ...} response into aws_message_id" do
    log = create_brevo_log()

    assert {:ok, updated} =
             Interceptor.update_after_send(log, %{id: "<brevo-message-id@brevo.com>"})

    assert updated.aws_message_id == "<brevo-message-id@brevo.com>"
    assert updated.message_id == log.message_id, "internal pk_ id must be kept, not overwritten"
    assert updated.status == "sent"
  end

  test "extracts from a string-keyed \"id\" response too (Swoosh's usual shape)" do
    log = create_brevo_log()

    assert {:ok, updated} =
             Interceptor.update_after_send(log, %{"id" => "<brevo-message-id-2@brevo.com>"})

    assert updated.aws_message_id == "<brevo-message-id-2@brevo.com>"
  end

  test "no crash and no aws_message_id when the response carries nothing extractable" do
    log = create_brevo_log()

    assert {:ok, updated} = Interceptor.update_after_send(log, %{})

    assert updated.aws_message_id == nil
    assert updated.status == "sent"
  end

  test "an aws_ses log is unaffected by the brevo_api clause (still extracts as before)" do
    {:ok, log} =
      %Log{}
      |> Log.changeset(%{
        message_id: "pk_#{System.unique_integer([:positive])}",
        to: "recipient@example.com",
        from: "sender@example.com",
        provider: "aws_ses",
        status: "queued"
      })
      |> Repo.insert()

    assert {:ok, updated} = Interceptor.update_after_send(log, %{"MessageId" => "ses-id-123"})
    assert updated.aws_message_id == "ses-id-123"
  end
end
