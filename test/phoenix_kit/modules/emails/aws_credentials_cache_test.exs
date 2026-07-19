defmodule PhoenixKit.Modules.Emails.AwsCredentialsCacheTest do
  @moduledoc """
  `Emails.aws_ses_credentials/0`'s caching layer. Every `get_aws_*/0`
  getter used to call `Integrations.get_credentials/1` (a DB round trip
  plus a decrypt) independently, so resolving one send-path config meant
  paying that cost 3 times over, on every single email. These tests seed a
  real `PhoenixKit.Cache` instance manually — the package's own test suite
  never boots core's `PhoenixKit.Supervisor`, so `aws_credentials_test.exs`
  exercises the (safe, gracefully-no-op) uncached path; this file is the
  one place the caching behavior itself is actually verified.

  `async: false`: `PhoenixKit.Cache.Registry` is a single, node-globally
  named process — starting it from multiple concurrently-running test
  files would conflict.
  """

  use PhoenixKitEmails.DataCase, async: false

  alias PhoenixKit.Cache
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Emails
  alias PhoenixKitEmails.Test.Repo

  @cache_name :emails_aws_credentials

  setup do
    case start_supervised(PhoenixKit.Cache.Registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, _pid} = start_supervised({Cache, name: @cache_name, ttl: 200})

    :ok
  end

  defp seed_aws_ses_integration(attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "test")
    {:ok, _} = Integrations.save_setup(uuid, attrs)
    uuid
  end

  test "a repeated call within the TTL does not re-query — still returns the cached value after the underlying connection is gone" do
    uuid =
      seed_aws_ses_integration(%{
        "access_key" => "AKIA_CACHED",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      })

    PhoenixKit.Settings.update_setting("emails_aws_integration_uuid", uuid)

    # Warms the cache.
    assert Emails.get_aws_access_key() == "AKIA_CACHED"

    # Delete the connection directly (bypassing invalidate_aws_credentials_cache/0)
    # — a real re-query at this point would find nothing and fall through
    # to the legacy Settings fallback (unset here, so it'd resolve "").
    Repo.delete_all(PhoenixKit.Settings.Setting)

    assert Emails.get_aws_access_key() == "AKIA_CACHED"
    assert Emails.get_aws_secret_key() == "S"
    assert Emails.get_aws_region() == "eu-central-1"
  end

  test "invalidate_aws_credentials_cache/0 makes the next call see fresh data immediately, not after the TTL" do
    uuid =
      seed_aws_ses_integration(%{
        "access_key" => "AKIA_OLD",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      })

    PhoenixKit.Settings.update_setting("emails_aws_integration_uuid", uuid)
    assert Emails.get_aws_access_key() == "AKIA_OLD"

    {:ok, _} = Integrations.save_setup(uuid, %{"access_key" => "AKIA_NEW"})

    # Without invalidation, the 200ms TTL would still be serving "AKIA_OLD".
    Emails.invalidate_aws_credentials_cache()

    assert Emails.get_aws_access_key() == "AKIA_NEW"
  end

  test "a cache entry past its TTL is not returned" do
    uuid =
      seed_aws_ses_integration(%{
        "access_key" => "AKIA_STALE",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      })

    PhoenixKit.Settings.update_setting("emails_aws_integration_uuid", uuid)
    assert Emails.get_aws_access_key() == "AKIA_STALE"

    {:ok, _} = Integrations.save_setup(uuid, %{"access_key" => "AKIA_FRESH"})

    # Past the 200ms TTL configured in setup/1, with no explicit invalidation.
    Process.sleep(250)

    assert Emails.get_aws_access_key() == "AKIA_FRESH"
  end
end
