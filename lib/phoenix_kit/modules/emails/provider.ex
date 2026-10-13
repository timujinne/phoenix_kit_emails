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
  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates
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

  # Templates — delegates to Templates context

  @impl PhoenixKit.Email.Provider
  def get_active_template_by_name(name), do: Templates.get_active_template_by_name(name)

  @impl PhoenixKit.Email.Provider
  def render_template(template, variables), do: Templates.render_template(template, variables)

  @impl PhoenixKit.Email.Provider
  def render_template(template, variables, locale),
    do: Templates.render_template(template, variables, locale)

  @impl PhoenixKit.Email.Provider
  def track_usage(%Template{} = template) do
    case Templates.track_usage(template) do
      {:ok, _used} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not count a use of template #{template.name}: #{inspect(reason)}")
    end
  end

  @impl PhoenixKit.Email.Provider
  def get_source_module(template), do: Template.get_source_module(template)

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

        # template_name / user_uuid / source_module opts → recorded on the email
        # log by the interceptor (so Details shows the template, user, and module).
        # skip_queue: a test send exists to give an immediate verdict. Queued,
        # it would flash "sent successfully" the moment Oban accepted the job —
        # before a relay had seen it, and while a later failure went unreported.
        email
        |> PhoenixKit.Mailer.deliver_email(
          template_name: template.name,
          user_uuid: user_uuid,
          source_module: "emails",
          skip_queue: true
        )
        |> count_use_if_delivered(template)

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
          source_module: "emails",
          skip_queue: true
        )
    end
  rescue
    error ->
      Logger.error("Failed to send test tracking email: #{inspect(error)}")
      {:error, error}
  end

  @doc false
  # A template is used when its message was delivered: an error, or a message a
  # dev transport only logged, leaves the count as it was. The delivery result
  # is returned unchanged, and a count that cannot be written does not turn a
  # delivered message into a failure.
  @spec count_use_if_delivered(term(), Template.t()) :: term()
  def count_use_if_delivered({:ok, %{suppressed: true}} = result, _template), do: result

  def count_use_if_delivered({:ok, _} = result, %Template{} = template) do
    try do
      track_usage(template)
    rescue
      error -> log_count_failure(template, error)
    catch
      :exit, reason -> log_count_failure(template, {:exit, reason})
    end

    result
  end

  def count_use_if_delivered(result, _template), do: result

  defp log_count_failure(template, reason) do
    Logger.warning("Could not count a use of template #{template.name}: #{inspect(reason)}")
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
