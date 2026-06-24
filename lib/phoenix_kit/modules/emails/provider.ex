defmodule PhoenixKit.Modules.Emails.Provider do
  @moduledoc "Unified email provider for PhoenixKit."

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKit.Modules.Emails.Utils

  # Interception — delegates to Interceptor

  def intercept_before_send(email, opts), do: Interceptor.intercept_before_send(email, opts)

  def handle_after_send(email, result) do
    case get_in(email.headers, ["X-PhoenixKit-Log-Id"]) do
      nil ->
        :ok

      log_uuid ->
        case Emails.get_log(log_uuid) do
          nil ->
            :ok

          log ->
            case result do
              {:ok, response} -> Interceptor.update_after_send(log, response)
              {:error, error} -> Interceptor.update_after_failure(log, error)
              _ -> :ok
            end
        end
    end
  rescue
    error ->
      Logger.error("Failed to update email tracking: #{inspect(error)}")
      :ok
  end

  # Templates — delegates to Templates context

  def get_active_template_by_name(name), do: Templates.get_active_template_by_name(name)

  def render_template(template, variables), do: Templates.render_template(template, variables)

  def render_template(template, variables, locale),
    do: Templates.render_template(template, variables, locale)

  def track_usage(template), do: Templates.track_usage(template)

  def get_source_module(template), do: Template.get_source_module(template)

  # AWS config — delegates to main Emails module

  def get_aws_region, do: Emails.get_aws_region()

  def get_aws_access_key, do: Emails.get_aws_access_key()

  def get_aws_secret_key, do: Emails.get_aws_secret_key()

  def aws_configured?, do: Emails.aws_configured?()

  # Provider detection — delegates to Emails.Utils

  def adapter_to_provider_name(adapter, default) do
    Utils.adapter_to_provider_name(adapter, default)
  end

  # Test tracking email — sends a test email with tracking enabled

  def send_test_tracking_email(recipient_email, user_uuid) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "PhoenixKit")
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    base =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient_email)
      |> Swoosh.Email.from({from_name, from_email})

    # Send the seeded "test_email" system template (auto-created by
    # seed_system_templates) so the test reflects a real template and the log /
    # Details capture template_name. Falls back to a built-in body if the
    # template is missing.
    case Templates.get_active_template_by_name("test_email") do
      %Template{} = template ->
        rendered =
          Templates.render_template(
            template,
            build_test_variables(template, recipient_email, timestamp)
          )

        email =
          base
          |> Swoosh.Email.subject(rendered.subject || "Test Tracking Email - #{timestamp}")
          |> Swoosh.Email.html_body(rendered.html_body || "")
          |> Swoosh.Email.text_body(rendered.text_body || "")

        Templates.track_usage(template)
        # template_name / user_uuid / source_module opts → recorded on the email
        # log by the interceptor (so Details shows the template, user, and module).
        PhoenixKit.Mailer.deliver_email(email,
          template_name: template.name,
          user_uuid: user_uuid,
          source_module: "emails"
        )

      _ ->
        email =
          base
          |> Swoosh.Email.subject("Test Tracking Email - #{timestamp}")
          |> Swoosh.Email.html_body("""
          <h1>Test Email</h1>
          <p>This is a test tracking email sent at #{timestamp}.</p>
          <p>Recipient: #{recipient_email}</p>
          """)
          |> Swoosh.Email.text_body(
            "Test Email\nSent at #{timestamp}\nRecipient: #{recipient_email}"
          )

        PhoenixKit.Mailer.deliver_email(email,
          template_name: "test_email",
          user_uuid: user_uuid,
          source_module: "emails"
        )
    end
  rescue
    error ->
      Logger.error("Failed to send test tracking email: #{inspect(error)}")
      {:error, error}
  end

  # Sample values for every variable the test_email template declares, so the
  # rendered test has no leftover {{placeholders}}.
  defp build_test_variables(template, recipient_email, timestamp) do
    template
    |> Template.extract_variables()
    |> Map.new(fn var -> {var, sample_variable_value(var, recipient_email, timestamp)} end)
  end

  defp sample_variable_value(var, recipient_email, timestamp) do
    v = String.downcase(to_string(var))

    cond do
      String.contains?(v, "email") -> recipient_email
      String.contains?(v, "recipient") -> recipient_email
      String.contains?(v, "name") or String.contains?(v, "user") -> "Test User"
      String.contains?(v, "date") or String.contains?(v, "time") -> timestamp
      String.contains?(v, "url") or String.contains?(v, "link") -> "https://example.com"
      String.contains?(v, "code") or String.contains?(v, "token") -> "123456"
      true -> "Sample #{var}"
    end
  end
end
