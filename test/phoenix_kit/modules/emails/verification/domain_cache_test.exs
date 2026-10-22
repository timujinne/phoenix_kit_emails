defmodule PhoenixKit.Modules.Emails.Verification.DomainCacheTest do
  use PhoenixKitEmails.DataCase, async: true

  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @resolution %{
    hosts: [%{host: "mx1.example.com", pref: 10}, %{host: "mx2.example.com", pref: 20}],
    implicit: false
  }

  defp hours_ago(now, hours), do: DateTime.add(now, -hours * 3600, :second)

  test "an unknown domain is a miss" do
    assert :miss = DomainCache.fetch_mx("unknown.example", UtilsDate.utc_now())
  end

  test "stores and returns an MX resolution" do
    now = UtilsDate.utc_now()
    assert :ok = DomainCache.store_mx("example.com", {:ok, @resolution}, now)
    assert {:hit, {:ok, @resolution}} = DomainCache.fetch_mx("example.com", now)
  end

  test "stores an implicit MX flag" do
    now = UtilsDate.utc_now()
    implicit = %{hosts: [%{host: "a-only.example", pref: 0}], implicit: true}
    DomainCache.store_mx("a-only.example", {:ok, implicit}, now)
    assert {:hit, {:ok, ^implicit}} = DomainCache.fetch_mx("a-only.example", now)
  end

  test "stores a definitive negative answer, with its reason" do
    now = UtilsDate.utc_now()

    for reason <- [:nxdomain, :no_records, :null_mx] do
      domain = "#{reason}.example"
      assert :ok = DomainCache.store_mx(domain, {:error, reason}, now)
      assert {:hit, {:error, ^reason}} = DomainCache.fetch_mx(domain, now)
    end
  end

  test "never stores a resolution marked uncacheable" do
    now = UtilsDate.utc_now()
    uncertain = %{hosts: [%{host: "a-only.example", pref: 0}], implicit: true, cacheable: false}
    assert :ok = DomainCache.store_mx("a-only.example", {:ok, uncertain}, now)
    assert :miss = DomainCache.fetch_mx("a-only.example", now)
  end

  test "never stores a transient failure" do
    now = UtilsDate.utc_now()

    for reason <- [:servfail, :timeout] do
      assert :ok = DomainCache.store_mx("flaky.example", {:error, reason}, now)
    end

    assert :miss = DomainCache.fetch_mx("flaky.example", now)
  end

  test "a later answer replaces the earlier one" do
    now = UtilsDate.utc_now()
    DomainCache.store_mx("changing.example", {:error, :nxdomain}, hours_ago(now, 30))
    DomainCache.store_mx("changing.example", {:ok, @resolution}, now)

    assert {:hit, {:ok, @resolution}} = DomainCache.fetch_mx("changing.example", now)
  end

  describe "TTL" do
    test "an MX answer is fresh for 24 hours by default" do
      now = UtilsDate.utc_now()
      DomainCache.store_mx("ttl.example", {:ok, @resolution}, hours_ago(now, 23))
      assert {:hit, _} = DomainCache.fetch_mx("ttl.example", now)

      DomainCache.store_mx("ttl.example", {:ok, @resolution}, hours_ago(now, 25))
      assert :miss = DomainCache.fetch_mx("ttl.example", now)
    end

    test "a no-MX answer has its own TTL setting" do
      now = UtilsDate.utc_now()
      Settings.update_setting_with_module("email_verify_ttl_no_mx_hours", "2", "email_system")

      DomainCache.store_mx("nomx.example", {:error, :nxdomain}, hours_ago(now, 1))
      assert {:hit, {:error, :nxdomain}} = DomainCache.fetch_mx("nomx.example", now)

      DomainCache.store_mx("nomx.example", {:error, :nxdomain}, hours_ago(now, 3))
      assert :miss = DomainCache.fetch_mx("nomx.example", now)

      # ...and the MX TTL is a different knob: 3 hours is still fresh for MX.
      DomainCache.store_mx("hasmx.example", {:ok, @resolution}, hours_ago(now, 3))
      assert {:hit, _} = DomainCache.fetch_mx("hasmx.example", now)
    end

    test "fresh?/3 reads the timestamp that belongs to each kind" do
      now = UtilsDate.utc_now()

      row = %DomainCache{
        domain: "kinds.example",
        mx_checked_at: hours_ago(now, 1),
        catch_all_checked_at: hours_ago(now, 24 * 8),
        grey_at: hours_ago(now, 25)
      }

      assert DomainCache.fresh?(row, :mx, now)
      assert DomainCache.fresh?(row, :no_mx, now)
      refute DomainCache.fresh?(row, :catch_all, now)
      refute DomainCache.fresh?(row, :grey, now)

      fresh_catch_all = %{row | catch_all_checked_at: hours_ago(now, 24 * 6)}
      assert DomainCache.fresh?(fresh_catch_all, :catch_all, now)

      refute DomainCache.fresh?(%DomainCache{domain: "never.example"}, :mx, now)
    end
  end
end
