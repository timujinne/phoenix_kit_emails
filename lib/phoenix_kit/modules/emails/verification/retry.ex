defmodule PhoenixKit.Modules.Emails.Verification.Retry do
  @moduledoc """
  Whether a batch job should try an address again, and when.

  One result is worth another attempt, a `"temp"` one:

    * `"dns_error"` - the lookup failed (SERVFAIL, timeout). Retried with a
      doubling backoff (60 s, 120 s, ... capped at 15 minutes), up to
      `email_verify_dns_max_attempts` attempts in all.

  A greylisted address is not retried here: the batch job only queues it for an SMTP
  session (`smtp_pending`), and the SMTP queue does the waiting (`SmtpQueue`).

  When the attempts run out the `"temp"` verdict simply stays. `snoozed` is how
  many times the job has already been put off (Oban's `meta["snoozed"]`).
  """

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Result

  @dns_backoff_base_s 60
  @dns_backoff_cap_s 900

  @doc "`{:snooze, seconds}` to try again later, `:done` to keep the verdict."
  @spec decide(Result.t(), non_neg_integer()) :: {:snooze, pos_integer()} | :done
  def decide(%Result{status: "temp", reason: "dns_error"}, snoozed) do
    if snoozed + 1 < Config.dns_max_attempts(),
      do: {:snooze, min(@dns_backoff_base_s * Integer.pow(2, snoozed), @dns_backoff_cap_s)},
      else: :done
  end

  def decide(%Result{}, _snoozed), do: :done
end
