defmodule PhoenixKit.Modules.Emails.Provider do
  @moduledoc """
  Unified email provider for PhoenixKit.

  Implements the `PhoenixKit.Email.Provider` behaviour, which core's
  `PhoenixKit.Mailer` calls through `Provider.current()`. The `@behaviour`
  declaration is load-bearing: without it the compiler cannot verify that this
  module actually satisfies the contract, so a callback added (or changed) in
  core would compile clean here and only blow up at runtime, in the send path.
  """

  @behaviour PhoenixKit.Email.Provider

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Interceptor
  alias PhoenixKit.Modules.Emails.Queue
  alias PhoenixKit.Modules.Emails.Utils

  # Interception — delegates to Interceptor

  @impl PhoenixKit.Email.Provider
  def intercept_before_send(email, opts), do: Interceptor.intercept_before_send(email, opts)

  # `maybe_enqueue/2` is an OPTIONAL callback that exists only in core versions
  # that ship the queue hook. There is no annotation that is warning-free against
  # both: with `@impl` an older core warns "function does not exist in
  # behaviour", without it a newer core warns "@impl was not set". We keep the
  # annotation and treat the newer core as the target — the floor in mix.exs must
  # be bumped to the first core release containing the callback when this ships,
  # which makes the older-core case impossible rather than merely quiet.
  @impl PhoenixKit.Email.Provider
  def maybe_enqueue(email, opts), do: Queue.maybe_enqueue(email, opts)

  @impl PhoenixKit.Email.Provider
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

  # AWS config — delegates to main Emails module

  @impl PhoenixKit.Email.Provider
  def get_aws_region, do: Emails.get_aws_region()

  @impl PhoenixKit.Email.Provider
  def get_aws_access_key, do: Emails.get_aws_access_key()

  @impl PhoenixKit.Email.Provider
  def get_aws_secret_key, do: Emails.get_aws_secret_key()

  @impl PhoenixKit.Email.Provider
  def aws_configured?, do: Emails.aws_configured?()

  # Provider detection — delegates to Emails.Utils

  @impl PhoenixKit.Email.Provider
  def adapter_to_provider_name(adapter, default) do
    Utils.adapter_to_provider_name(adapter, default)
  end

  # Test tracking email — sends a test email with tracking enabled

  @impl PhoenixKit.Email.Provider
  def send_test_tracking_email(recipient_email, user_uuid) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "PhoenixKit")
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    base =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient_email)
      |> Swoosh.Email.from({from_name, from_email})

    email =
      base
      |> Swoosh.Email.subject("Test Tracking Email - #{timestamp}")
      |> Swoosh.Email.html_body("""
      <h1>Test Email</h1>
      <p>This is a test tracking email sent at #{timestamp}.</p>
      <p>Recipient: #{recipient_email}</p>
      """)
      |> Swoosh.Email.text_body("Test Email\nSent at #{timestamp}\nRecipient: #{recipient_email}")

    # The body is built in code above: no template layer builds it (the
    # database template this test used to render is retired).
    PhoenixKit.Mailer.deliver_email(email,
      template_name: "test_email",
      template_source: nil,
      user_uuid: user_uuid,
      source_module: "emails",
      skip_queue: true
    )
  rescue
    error ->
      Logger.error("Failed to send test tracking email: #{inspect(error)}")
      {:error, error}
  end
end
