defmodule PhoenixKit.Modules.Emails.Verification.Config do
  @moduledoc """
  Reads the verification engine's configuration.

  Everything an operator can change lives in PhoenixKit settings (module
  `"email_system"`, prefix `email_verify_`); the two behaviour implementations
  and the external lists directory can also be set in the application env
  (`config :phoenix_kit_emails, ...`), which is what tests and host apps with
  private word lists use.

  ## Settings

    * `email_verify_enabled` - the feature switch (default `true`)
    * `email_verify_smtp_mode` - who opens the SMTP connections: `"off"` (default, no
      SMTP at all), `"runner"` (an agent on the user's machine, through the machine
      API) or `"local"` (this server, through its built-in runner); anything else counts as
      `"off"`
    * `email_verify_smtp_mail_from` - an override for the `MAIL FROM` address (empty
      by default: the site's sender address is used), see `smtp_mail_from/0`
    * `email_verify_smtp_helo` - the `EHLO` name; empty means "the reverse DNS of the
      sending IP, found by the runner, else the machine's own host name" (never a
      loopback or private address). Only a plain host name or an IPv4 address
      literal is accepted, anything else counts as empty, see `smtp_helo/0`
    * `email_verify_rcpt_per_session` - addresses of one domain per SMTP session (default `10`)
    * `email_verify_domain_interval_s` - least gap between two sessions to one domain
      (default `10`)
    * `email_verify_smtp_lease_s` - how long a runner holds a session before it is
      taken back (default `300`; never less than `smtp_lease_floor_s/0`, so a session
      that runs as long as it is allowed to cannot outlive its lease)
    * `email_verify_smtp_max_attempts` - sessions lost to an expired lease before the
      address is given up as `smtp_unavailable` (default `5`)
    * `email_verify_smtp_queue_max_age_h` - hours an address may wait in the SMTP queue
      before it is given up as `smtp_unavailable`, whether or not a runner is alive
      (default `48`)
    * `email_verify_smtp_claim_dns_budget_ms` - how long one claim may spend on DNS for
      domains whose cached MX has run out; past it the other such domains stay queued
      for the next claim (default `10000`)
    * `email_verify_smtp_connect_timeout_s` / `email_verify_smtp_read_timeout_s` -
      handed to the runner (default `20` / `30`)
    * `email_verify_smtp_idle_poll_s` - the runner's pause on an empty answer; the runner
      counts as online while it was seen within three times this (default `30`)
    * `email_verify_domain_block_threshold` / `email_verify_domain_block_window_min` /
      `email_verify_domain_pause_min` - this many blocks within the window pause the
      domain for the pause (default `2` / `60` / `60`)
    * `email_verify_runner_fail_sessions` / `email_verify_runner_fail_domains` /
      `email_verify_runner_pause_min` - this many failed sessions in a row, on at
      least this many different domains, pause the runner for the pause
      (default `5` / `3` / `60`)
    * `email_verify_smtp_selftest_host` - the host the runner's port 25 self-test
      connects to (empty: derived, see `Verification.Runners.selftest_host/0`)
    * `email_verify_ttl_mx_hours` - cached MX answer (default `24`)
    * `email_verify_ttl_no_mx_hours` - cached "no MX / no such domain" (default `24`)
    * `email_verify_ttl_catch_all_days` - cached catch-all probe (default `7`)
    * `email_verify_ttl_grey_hours` - cached greylist marker (default `24`)
    * `email_verify_ttl_result_days` - a stored verdict is reused this long (default `30`)
    * `email_verify_dns_timeout_ms` - the deadline of one DNS query, retransmissions
      included (default `3000`); the worst case for one domain is eight times that,
      see `Verification.Resolver.Inet`
    * `email_verify_disposable_status` - the status of an address on a disposable
      domain: `"temp"` (default, what LetsExtract does) or `"invalid"`; any other
      value counts as `"temp"`. The `disposable` flag is set either way
    * `email_verify_dns_max_attempts` - how many times a batch job tries an address
      whose DNS lookup failed transiently before keeping the `temp` verdict (default `3`)
    * `email_verify_grey_retry_minutes` - wait before a greylisted address is
      tried again in the SMTP queue (default `20`)
    * `email_verify_grey_max_attempts` - greylist attempts before the `temp` verdict
      is kept (default `3`)
    * `email_verify_lists_dir` - optional external dictionary directory

  ## Application env (`:phoenix_kit_emails`)

    * `:verification_resolver` - a `Verification.Resolver` module (default `Resolver.Inet`)
    * `:verification_lists_dir` - external dictionary directory; wins over the setting
    * `:verification_machine_api` - `false` pretends the core has no machine API
    * `:verification_smtp_port` - the port the built-in runner (mode `local`) connects to
      (default `25`; tests point it at a fake mail host)
    * `:verification_smtp_loopback_only` - `true` makes the built-in runner raise instead
      of connecting to anything but 127.0.0.0/8 and `::1` (the test config sets it)
    * `:verification_local_sessions` - sessions the built-in runner runs at a time
      (default `3`)
    * `:verification_confirm_pause_ms` - the pause before a negative DNS answer is
      asked a second time, in milliseconds (default `300`, at most `2000`, `0`
      switches it off; the test config sets `0`)
  """

  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKit.Modules.Emails.Verification.Syntax
  alias PhoenixKit.Settings

  @type ttl_kind :: :mx | :no_mx | :catch_all | :grey | :result
  @type smtp_mode :: String.t()
  @type mail_from_source :: :override | :site_sender | :none

  @smtp_modes ~w(off runner local)
  @placeholder_domains ~w(localhost example.com example.org example.net)

  @session_hard_limit_s 240
  @lease_margin_s 60

  @default_dns_timeout_ms 3_000
  @default_confirm_pause_ms 300
  @max_confirm_pause_ms 2_000

  @doc "Whether the verification feature is switched on (default `true`)."
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting("email_verify_enabled", true)
  rescue
    _ -> false
  end

  @doc """
  The SMTP mode as stored: `"off"` (default), `"runner"` or `"local"`. Anything
  else, or an unreadable store, is `"off"`. For the settings UI; the pipeline asks
  `smtp_mode/0`.
  """
  @spec smtp_mode_setting() :: smtp_mode()
  def smtp_mode_setting do
    case Settings.get_setting("email_verify_smtp_mode") do
      value when is_binary(value) ->
        mode = value |> String.trim() |> String.downcase()
        if mode in @smtp_modes, do: mode, else: "off"

      _ ->
        "off"
    end
  rescue
    _ -> "off"
  end

  @doc """
  The SMTP mode in effect. `"runner"` needs the machine API of core
  (`machine_api_available?/0`); on a core without it the mode reads `"off"`, so
  addresses are never queued for a runner that cannot connect.
  """
  @spec smtp_mode() :: smtp_mode()
  def smtp_mode do
    case smtp_mode_setting() do
      "runner" -> if machine_api_available?(), do: "runner", else: "off"
      mode -> mode
    end
  end

  @doc "Whether the SMTP step is active (`smtp_mode/0` is not `\"off\"`)."
  @spec smtp_enabled?() :: boolean()
  def smtp_enabled?, do: smtp_mode() != "off"

  @doc """
  Whether the core installed here has the machine API a runner connects through (core
  2.63.0 and later). The application env `:verification_machine_api` set to `false`
  says "no" regardless (it lets a test stand in for an older core).
  """
  @spec machine_api_available?() :: boolean()
  def machine_api_available? do
    Application.get_env(:phoenix_kit_emails, :verification_machine_api, true) != false and
      Code.ensure_loaded?(PhoenixKit.API.Keys)
  end

  @doc """
  The `MAIL FROM` address of SMTP sessions and where it came from.

  The override setting (`email_verify_smtp_mail_from`) wins when it is a usable
  address; otherwise the site's configured sender (`PhoenixKit.Mailer.get_from_email/0`,
  verified with the mail provider) is used. A placeholder (domain `localhost`,
  `example.com`/`.org`/`.net`, a domain with no dot) or an invalid address counts as
  not configured: `{nil, :none}`, and no SMTP session may start without a sender.
  """
  @spec smtp_mail_from() :: {String.t() | nil, mail_from_source()}
  def smtp_mail_from do
    case usable_sender(override_mail_from()) do
      {:ok, address} ->
        {address, :override}

      :error ->
        case usable_sender(site_sender()) do
          {:ok, address} -> {address, :site_sender}
          :error -> {nil, :none}
        end
    end
  end

  @doc "The override setting alone (empty by default), trimmed."
  @spec smtp_mail_from_override() :: String.t()
  def smtp_mail_from_override, do: override_mail_from()

  @doc "The site's sender address, or `nil` when it is not a usable address."
  @spec site_sender_address() :: String.t() | nil
  def site_sender_address do
    case usable_sender(site_sender()) do
      {:ok, address} -> address
      :error -> nil
    end
  end

  @doc """
  The `EHLO` name override, or `nil` for "the runner works it out from its IP".

  The value is written into the SMTP dialogue by the runner, so only a plain host
  name (letters, digits and hyphens in labels of 1 to 63 characters, dots between
  them, 255 bytes at most) or an IPv4 address literal (`[203.0.113.9]`) passes;
  anything else - a line break, a space, a control character - reads as `nil`.
  """
  @spec smtp_helo() :: String.t() | nil
  def smtp_helo do
    case blank_to_nil(text_setting("email_verify_smtp_helo")) do
      nil -> nil
      value -> if helo?(value), do: value, else: nil
    end
  end

  @doc """
  The normalised form of `address` when it can be a `MAIL FROM` (valid syntax, not a
  placeholder such as `localhost` or `example.com`), `:error` otherwise. What the
  settings form checks an override with.
  """
  @spec usable_sender_address(term()) :: {:ok, String.t()} | :error
  def usable_sender_address(address), do: usable_sender(address)

  @doc """
  Whether `value` is accepted as the `EHLO` name (see `smtp_helo/0`). What the settings
  form checks the field with.
  """
  @spec helo_name?(term()) :: boolean()
  def helo_name?(value) when is_binary(value), do: value != "" and helo?(value)
  def helo_name?(_value), do: false

  @doc "The host a runner's port 25 self-test is pointed at, if one is set (otherwise it is derived)."
  @spec smtp_selftest_host_setting() :: String.t() | nil
  def smtp_selftest_host_setting,
    do: blank_to_nil(text_setting("email_verify_smtp_selftest_host"))

  @doc "Addresses of one domain in one SMTP session."
  @spec rcpt_per_session() :: pos_integer()
  def rcpt_per_session, do: min(positive_integer("email_verify_rcpt_per_session", 10), 100)

  @doc "Least seconds between two SMTP sessions to one domain."
  @spec domain_interval_s() :: pos_integer()
  def domain_interval_s, do: positive_integer("email_verify_domain_interval_s", 10)

  @doc """
  The longest one SMTP session runs, seconds: both the PowerShell runner and
  the built-in runner stop a session at this limit, whatever the connect and read timeouts add up to.
  """
  @spec session_hard_limit_s() :: pos_integer()
  def session_hard_limit_s, do: @session_hard_limit_s

  @doc """
  The least a lease may be, seconds: the hard limit of a session plus a margin for the
  report to come back. A shorter lease would expire under a session that is still allowed
  to run, and the address would be handed out again.
  """
  @spec smtp_lease_floor_s() :: pos_integer()
  def smtp_lease_floor_s, do: @session_hard_limit_s + @lease_margin_s

  @doc "Seconds a runner may hold a session: the setting, but not below `smtp_lease_floor_s/0`."
  @spec smtp_lease_s() :: pos_integer()
  def smtp_lease_s,
    do: max(positive_integer("email_verify_smtp_lease_s", 300), smtp_lease_floor_s())

  @doc "Sessions lost to an expired lease before an address is given up."
  @spec smtp_max_attempts() :: pos_integer()
  def smtp_max_attempts, do: positive_integer("email_verify_smtp_max_attempts", 5)

  @doc "Seconds an address may wait in the SMTP queue before it is given up."
  @spec smtp_queue_max_age_s() :: pos_integer()
  def smtp_queue_max_age_s, do: hours("email_verify_smtp_queue_max_age_h", 48)

  @doc "Milliseconds one claim may spend on DNS lookups."
  @spec claim_dns_budget_ms() :: pos_integer()
  def claim_dns_budget_ms, do: positive_integer("email_verify_smtp_claim_dns_budget_ms", 10_000)

  @doc "The runner's connect timeout, seconds."
  @spec smtp_connect_timeout_s() :: pos_integer()
  def smtp_connect_timeout_s, do: positive_integer("email_verify_smtp_connect_timeout_s", 20)

  @doc "The runner's read timeout, seconds."
  @spec smtp_read_timeout_s() :: pos_integer()
  def smtp_read_timeout_s, do: positive_integer("email_verify_smtp_read_timeout_s", 30)

  @doc "How long the runner sleeps after an empty answer, seconds."
  @spec idle_poll_s() :: pos_integer()
  def idle_poll_s, do: positive_integer("email_verify_smtp_idle_poll_s", 30)

  @doc "Blocks within `domain_block_window_s/0` that pause a domain."
  @spec domain_block_threshold() :: pos_integer()
  def domain_block_threshold, do: positive_integer("email_verify_domain_block_threshold", 2)

  @doc "The window, in seconds, in which blocks are counted."
  @spec domain_block_window_s() :: pos_integer()
  def domain_block_window_s, do: positive_integer("email_verify_domain_block_window_min", 60) * 60

  @doc "How long a blocking domain is left alone, seconds."
  @spec domain_pause_s() :: pos_integer()
  def domain_pause_s, do: positive_integer("email_verify_domain_pause_min", 60) * 60

  @doc "Failed sessions in a row that pause the runner."
  @spec runner_fail_sessions() :: pos_integer()
  def runner_fail_sessions, do: positive_integer("email_verify_runner_fail_sessions", 5)

  @doc "Different domains those failed sessions must span."
  @spec runner_fail_domains() :: pos_integer()
  def runner_fail_domains, do: positive_integer("email_verify_runner_fail_domains", 3)

  @doc "How long a paused runner is left alone, seconds."
  @spec runner_pause_s() :: pos_integer()
  def runner_pause_s, do: positive_integer("email_verify_runner_pause_min", 60) * 60

  @doc "How long a cached fact (or a stored verdict) stays fresh, in seconds."
  @spec ttl_seconds(ttl_kind()) :: pos_integer()
  def ttl_seconds(:mx), do: hours("email_verify_ttl_mx_hours", 24)
  def ttl_seconds(:no_mx), do: hours("email_verify_ttl_no_mx_hours", 24)
  def ttl_seconds(:grey), do: hours("email_verify_ttl_grey_hours", 24)
  def ttl_seconds(:catch_all), do: days("email_verify_ttl_catch_all_days", 7)
  def ttl_seconds(:result), do: days("email_verify_ttl_result_days", 30)

  @doc """
  The status a disposable-domain address gets: `"temp"` (the default) or
  `"invalid"`, from `email_verify_disposable_status` (case and surrounding spaces
  ignored; anything unrecognised, or an unreadable store, is `"temp"`).
  """
  @spec disposable_status() :: String.t()
  def disposable_status do
    case Settings.get_setting("email_verify_disposable_status") do
      value when is_binary(value) ->
        if value |> String.trim() |> String.downcase() == "invalid", do: "invalid", else: "temp"

      _ ->
        "temp"
    end
  rescue
    _ -> "temp"
  end

  @doc "How many attempts a batch job makes on an address whose DNS lookup fails transiently."
  @spec dns_max_attempts() :: pos_integer()
  def dns_max_attempts, do: positive_integer("email_verify_dns_max_attempts", 3)

  @doc "How many times the SMTP queue tries a greylisted address."
  @spec grey_max_attempts() :: pos_integer()
  def grey_max_attempts, do: positive_integer("email_verify_grey_max_attempts", 3)

  @doc "The wait, in minutes, before a greylisted address is tried again."
  @spec grey_retry_minutes() :: pos_integer()
  def grey_retry_minutes, do: positive_integer("email_verify_grey_retry_minutes", 20)

  @doc "The deadline of one DNS query (all its retransmissions), in milliseconds."
  @spec dns_timeout_ms() :: pos_integer()
  def dns_timeout_ms do
    positive_integer("email_verify_dns_timeout_ms", @default_dns_timeout_ms)
  end

  @doc """
  How long, in milliseconds, the resolver waits before it asks a negative DNS
  answer a second time: from the application env, `300` by default, never more
  than `2000`. A value that is not a non-negative integer is the default.
  """
  @spec confirm_pause_ms() :: non_neg_integer()
  def confirm_pause_ms do
    case Application.get_env(:phoenix_kit_emails, :verification_confirm_pause_ms) do
      ms when is_integer(ms) and ms >= 0 -> min(ms, @max_confirm_pause_ms)
      _ -> @default_confirm_pause_ms
    end
  end

  @doc "The DNS resolver implementation."
  @spec resolver() :: module()
  def resolver do
    Application.get_env(:phoenix_kit_emails, :verification_resolver, Resolver.Inet)
  end

  @doc "The external dictionary directory, or `nil`."
  @spec lists_dir() :: String.t() | nil
  def lists_dir do
    case lists_dir_lookup() do
      {:ok, dir} -> dir
      :error -> nil
    end
  end

  @doc """
  Like `lists_dir/0`, but says when the answer is not trustworthy: `:error`
  means the settings store could not be read (the database is not ready yet),
  which is not the same as "no directory configured" (`{:ok, nil}`).
  """
  @spec lists_dir_lookup() :: {:ok, String.t() | nil} | :error
  def lists_dir_lookup do
    case Application.get_env(:phoenix_kit_emails, :verification_lists_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> setting_dir()
    end
  end

  defp setting_dir do
    case Settings.get_setting("email_verify_lists_dir") do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:ok, nil}
    end
  rescue
    _ -> :error
  end

  defp override_mail_from, do: "email_verify_smtp_mail_from" |> text_setting() |> String.trim()

  defp site_sender do
    PhoenixKit.Mailer.get_from_email()
  rescue
    _ -> nil
  end

  # The normalised address (domain lowercase and in punycode), which is what goes
  # into `MAIL FROM`. A local part with non-ASCII characters is refused by the syntax
  # check: it would need SMTPUTF8.
  defp usable_sender(address) when is_binary(address) do
    with {:ok, %{email: email, local: local, domain: domain}} <- Normalizer.normalize(address),
         :ok <- Syntax.check(local, domain),
         false <- placeholder_domain?(domain) do
      {:ok, email}
    else
      _ -> :error
    end
  end

  defp usable_sender(_address), do: :error

  defp placeholder_domain?(domain) do
    not String.contains?(domain, ".") or
      Enum.any?(@placeholder_domains, &(domain == &1 or String.ends_with?(domain, "." <> &1)))
  end

  @helo_label ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/
  @address_literal ~r/\A\[([0-9.]+)\]\z/

  defp helo?(value) when byte_size(value) > 255, do: false

  defp helo?(value) do
    case Regex.run(@address_literal, value) do
      [_, ip] -> match?({:ok, _}, :inet.parse_ipv4strict_address(String.to_charlist(ip)))
      nil -> value |> String.split(".") |> Enum.all?(&Regex.match?(@helo_label, &1))
    end
  end

  defp text_setting(key) do
    case Settings.get_setting(key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp hours(key, default), do: positive_integer(key, default) * 3_600
  defp days(key, default), do: positive_integer(key, default) * 86_400

  defp positive_integer(key, default) do
    case Settings.get_integer_setting(key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  rescue
    _ -> default
  end
end
