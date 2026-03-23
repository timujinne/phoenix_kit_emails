defmodule PhoenixKit.Modules.Emails.Provider do
  @moduledoc "Implements PhoenixKit.Email.Provider — unified email provider."
  @behaviour PhoenixKit.Email.Provider

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates

  # Interception — delegates to Interceptor
  @impl true
  def intercept_before_send(email, opts), do: Interceptor.intercept_before_send(email, opts)

  @impl true
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
      require Logger
      Logger.error("Failed to update email tracking: #{inspect(error)}")
      :ok
  end

  # Templates — delegates to Templates context
  @impl true
  def get_active_template_by_name(name), do: Templates.get_active_template_by_name(name)

  @impl true
  def render_template(template, variables), do: Templates.render_template(template, variables)

  @impl true
  def render_template(template, variables, locale),
    do: Templates.render_template(template, variables, locale)

  @impl true
  def track_usage(template), do: Templates.track_usage(template)

  @impl true
  def get_source_module(template), do: Template.get_source_module(template)

  # AWS config — delegates to main Emails module
  @impl true
  def get_aws_region, do: Emails.get_aws_region()

  @impl true
  def get_aws_access_key, do: Emails.get_aws_access_key()

  @impl true
  def get_aws_secret_key, do: Emails.get_aws_secret_key()

  @impl true
  def aws_configured?, do: Emails.aws_configured?()

  # Provider detection — delegates to Emails.Utils
  @impl true
  def adapter_to_provider_name(adapter, default) do
    PhoenixKit.Modules.Emails.Utils.adapter_to_provider_name(adapter, default)
  end

  # Test tracking email — sends a test email with tracking enabled
  @impl true
  def send_test_tracking_email(recipient_email, _user_uuid) do
    require Logger

    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "PhoenixKit")
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient_email)
      |> Swoosh.Email.from({from_name, from_email})
      |> Swoosh.Email.subject("Test Tracking Email - #{timestamp}")
      |> Swoosh.Email.html_body("""
      <h1>Test Email</h1>
      <p>This is a test tracking email sent at #{timestamp}.</p>
      <p>Recipient: #{recipient_email}</p>
      """)
      |> Swoosh.Email.text_body("Test Email\nSent at #{timestamp}\nRecipient: #{recipient_email}")

    PhoenixKit.Mailer.deliver_email(email)
  rescue
    error ->
      Logger.error("Failed to send test tracking email: #{inspect(error)}")
      {:error, error}
  end
end
