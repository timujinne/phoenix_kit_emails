defmodule PhoenixKit.Modules.Emails.Verification.SmtpSettings do
  @moduledoc """
  The writing side of the SMTP settings the "Mailbox verification (SMTP)" section shows:
  the mode, the `MAIL FROM` override, the `EHLO` name, the self-test host and the
  numbers of the SMTP stage (`Verification.Config` reads them).

  `save/2` validates the whole form first and writes nothing unless every field is
  fine; it then writes only the fields whose value differs from the one in force, so a
  default the form merely shows is never frozen into the settings. Errors are `%{field => reason}` with the reasons `:address`, `:helo`,
  `:integer` (not a whole number above zero), `{:max, n}` and `{:min, n}` (the lease of
  a session cannot be shorter than `Config.smtp_lease_floor_s/0`); the section turns them
  into text. `save_mode/2` is separate: the mode takes effect at once, going to
  `off` settles what is waiting in the SMTP queue (`SmtpQueue.drain_disabled/0`) and
  going to `local` starts the built-in runner (`LocalRunner.activate/0`).
  """

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.LocalRunner
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Settings

  @modes ~w(off local runner)
  @module "email_system"
  @largest 1_000_000

  # {form field, setting, the largest value}. The order is the order of the form.
  @numbers [
    {"rcpt_per_session", "email_verify_rcpt_per_session", 100},
    {"domain_interval_s", "email_verify_domain_interval_s", @largest},
    {"grey_retry_minutes", "email_verify_grey_retry_minutes", @largest},
    {"grey_max_attempts", "email_verify_grey_max_attempts", @largest},
    {"smtp_lease_s", "email_verify_smtp_lease_s", @largest},
    {"smtp_max_attempts", "email_verify_smtp_max_attempts", @largest},
    {"smtp_connect_timeout_s", "email_verify_smtp_connect_timeout_s", @largest},
    {"smtp_read_timeout_s", "email_verify_smtp_read_timeout_s", @largest},
    {"smtp_idle_poll_s", "email_verify_smtp_idle_poll_s", @largest},
    {"domain_block_threshold", "email_verify_domain_block_threshold", @largest},
    {"domain_block_window_min", "email_verify_domain_block_window_min", @largest},
    {"domain_pause_min", "email_verify_domain_pause_min", @largest},
    {"runner_fail_sessions", "email_verify_runner_fail_sessions", @largest},
    {"runner_fail_domains", "email_verify_runner_fail_domains", @largest},
    {"runner_pause_min", "email_verify_runner_pause_min", @largest}
  ]

  @texts [
    {"mail_from", "email_verify_smtp_mail_from", :address},
    {"helo", "email_verify_smtp_helo", :helo},
    {"selftest_host", "email_verify_smtp_selftest_host", :helo}
  ]

  @type errors :: %{
          optional(String.t()) =>
            :address | :helo | :integer | {:max, pos_integer()} | {:min, pos_integer()}
        }

  @doc "The names of the numeric fields, in the order of the form."
  @spec number_fields() :: [String.t()]
  def number_fields, do: Enum.map(@numbers, fn {field, _setting, _max} -> field end)

  @doc """
  What the form shows: `:mode`, the three texts as stored (`:mail_from`, `:helo`,
  `:selftest_host`, empty strings when not set) and `:numbers`, a map from field name
  to the value in force.
  """
  @spec current() :: %{
          mode: String.t(),
          mail_from: String.t(),
          helo: String.t(),
          selftest_host: String.t(),
          numbers: %{String.t() => pos_integer()}
        }
  def current do
    %{
      mode: Config.smtp_mode_setting(),
      mail_from: Config.smtp_mail_from_override(),
      helo: Config.smtp_helo() || "",
      selftest_host: Config.smtp_selftest_host_setting() || "",
      numbers: Map.new(@numbers, fn {field, _setting, _max} -> {field, value(field)} end)
    }
  end

  defp value("rcpt_per_session"), do: Config.rcpt_per_session()
  defp value("domain_interval_s"), do: Config.domain_interval_s()
  defp value("grey_retry_minutes"), do: Config.grey_retry_minutes()
  defp value("grey_max_attempts"), do: Config.grey_max_attempts()
  defp value("smtp_lease_s"), do: Config.smtp_lease_s()
  defp value("smtp_max_attempts"), do: Config.smtp_max_attempts()
  defp value("smtp_connect_timeout_s"), do: Config.smtp_connect_timeout_s()
  defp value("smtp_read_timeout_s"), do: Config.smtp_read_timeout_s()
  defp value("smtp_idle_poll_s"), do: Config.idle_poll_s()
  defp value("domain_block_threshold"), do: Config.domain_block_threshold()
  defp value("domain_block_window_min"), do: div(Config.domain_block_window_s(), 60)
  defp value("domain_pause_min"), do: div(Config.domain_pause_s(), 60)
  defp value("runner_fail_sessions"), do: Config.runner_fail_sessions()
  defp value("runner_fail_domains"), do: Config.runner_fail_domains()
  defp value("runner_pause_min"), do: div(Config.runner_pause_s(), 60)

  @doc """
  Stores the mode. `{:ok, %{mode:, drained:}}`; `drained` is how many queued addresses
  were settled as `smtp_disabled` because the mode is now `off` (0 for the other modes,
  which keep their queue). `{:error, :invalid_mode}` for anything but `off`, `local`,
  `runner`; `{:error, :runner_unavailable}` for `runner` on a core without the machine
  API; `{:error, :not_saved}` when the store refuses.

  `opts` may carry `:actor_uuid` (who changed it), which goes into the settings history.
  """
  @spec save_mode(term(), keyword()) ::
          {:ok, %{mode: String.t(), drained: non_neg_integer()}}
          | {:error, :invalid_mode | :runner_unavailable | :not_saved}
  def save_mode(mode, opts \\ [])

  def save_mode(mode, opts) when mode in @modes do
    with :ok <- check_available(mode),
         {:ok, _setting} <- write("email_verify_smtp_mode", mode, opts) do
      {:ok, %{mode: mode, drained: after_mode(mode)}}
    else
      {:error, :runner_unavailable} -> {:error, :runner_unavailable}
      {:error, _changeset} -> {:error, :not_saved}
    end
  end

  def save_mode(_mode, _opts), do: {:error, :invalid_mode}

  # What a switch to `mode` sets going: `off` settles what waits (the count), `local`
  # starts the built-in runner (with its port 25 self-test).
  defp after_mode("off"), do: SmtpQueue.drain_disabled()

  defp after_mode("local") do
    LocalRunner.activate()
    0
  end

  defp after_mode(_mode), do: 0

  defp check_available("runner") do
    if Config.machine_api_available?(), do: :ok, else: {:error, :runner_unavailable}
  end

  defp check_available(_mode), do: :ok

  @doc """
  Validates the form and writes it. A field missing from `params` keeps its value; a
  text field that is present and empty clears its override.

    * `"mail_from"` - empty, or an address `Config.usable_sender_address/1` accepts
    * `"helo"` and `"selftest_host"` - empty, or a name `Config.helo_name?/1` accepts
    * the fields of `number_fields/0` - a whole number from 1 (addresses per session:
      up to 100; time to finish a session: from `Config.smtp_lease_floor_s/0`)

  `{:ok, current()}` or `{:error, errors}` (nothing written for invalid fields;
  `%{"base" => :not_saved}` when the store itself refused a write, in which case the
  fields written before it stay written). `opts` may carry `:actor_uuid`, which goes into
  the settings history.
  """
  @spec save(map(), keyword()) :: {:ok, map()} | {:error, errors() | %{String.t() => :not_saved}}
  def save(params, opts \\ []) when is_map(params) do
    case checked(params) do
      {:ok, writes} -> write_all(writes, opts)
      {:error, _errors} = error -> error
    end
  end

  # Every present field is checked, so that the form shows all the wrong ones at once.
  defp checked(params) do
    numbers =
      Enum.map(@numbers, fn {field, setting, max} ->
        {field, setting, {:number, minimum(field), max}}
      end)

    results =
      (@texts ++ numbers)
      |> Enum.filter(fn {field, _setting, _kind} -> Map.has_key?(params, field) end)
      |> Enum.map(fn {field, setting, kind} ->
        {field, setting, check(kind, Map.fetch!(params, field))}
      end)

    case for({field, _setting, {:error, reason}} <- results, do: {field, reason}) do
      [] -> {:ok, for({field, setting, {:ok, text}} <- results, do: {field, setting, text})}
      errors -> {:error, Map.new(errors)}
    end
  end

  defp write_all(writes, opts) do
    in_force = in_force()

    failed? =
      writes
      |> Enum.reject(fn {field, _setting, text} -> Map.fetch!(in_force, field) == text end)
      |> Enum.any?(fn {_field, setting, text} ->
        not match?({:ok, _}, write(setting, text, opts))
      end)

    if failed?, do: {:error, %{"base" => :not_saved}}, else: {:ok, current()}
  end

  # The form fields with the text they would be saved as, to leave unchanged ones alone.
  defp in_force do
    current = current()

    %{
      "mail_from" => current.mail_from,
      "helo" => current.helo,
      "selftest_host" => current.selftest_host
    }
    |> Map.merge(Map.new(current.numbers, fn {field, number} -> {field, to_string(number)} end))
  end

  defp check({:number, min, max}, value), do: check_number(min, max, value)
  defp check(kind, value), do: check_text(kind, value)

  defp check_text(kind, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, ""}
      text -> check_text_value(kind, text)
    end
  end

  defp check_text(kind, _value), do: {:error, kind}

  defp check_text_value(:address, text) do
    case Config.usable_sender_address(text) do
      {:ok, _normalised} -> {:ok, text}
      :error -> {:error, :address}
    end
  end

  defp check_text_value(:helo, text) do
    if Config.helo_name?(text), do: {:ok, text}, else: {:error, :helo}
  end

  defp check_number(min, max, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 and number < min -> {:error, {:min, min}}
      {number, ""} when number > 0 and number <= max -> {:ok, Integer.to_string(number)}
      {number, ""} when number > max and max < @largest -> {:error, {:max, max}}
      _ -> {:error, :integer}
    end
  end

  defp check_number(_min, _max, _value), do: {:error, :integer}

  # A session may run up to its hard limit, so its lease cannot be shorter than that.
  defp minimum("smtp_lease_s"), do: Config.smtp_lease_floor_s()
  defp minimum(_field), do: 1

  # The store refuses an empty value: clearing an override deletes the setting, and
  # clearing one that was never stored is not an error.
  defp write(setting, "", _opts), do: clear(Settings.delete_setting(setting))

  # Older cores have no options (the history of who changed what).
  defp write(setting, text, opts) do
    if opts != [] and function_exported?(Settings, :update_setting_with_module, 4) do
      Settings.update_setting_with_module(setting, text, @module, opts)
    else
      Settings.update_setting_with_module(setting, text, @module)
    end
  end

  defp clear({:error, :not_found}), do: {:ok, :cleared}
  defp clear(other), do: other
end
