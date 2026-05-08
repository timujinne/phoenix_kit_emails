defmodule PhoenixKit.Modules.Emails.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every admin tab registered by `PhoenixKit.Modules.Emails.admin_tabs/0`
      carries `gettext_backend: PhoenixKit.Modules.Emails.Gettext`.
    * Locale switching on the module's own backend produces translated
      labels for at least one well-known msgid (regression guard for
      the `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with
      the package).
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: false

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.Gettext, as: EmailsGettext

  setup do
    original = Gettext.get_locale(EmailsGettext)
    on_exit(fn -> Gettext.put_locale(EmailsGettext, original) end)
    :ok
  end

  describe "admin_tabs/0 wiring" do
    test "every tab carries the module's own gettext backend" do
      for tab <- Emails.admin_tabs() do
        assert tab.gettext_backend == EmailsGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'Emails' tab to 'Письма'" do
      Gettext.put_locale(EmailsGettext, "ru")

      parent = Enum.find(Emails.admin_tabs(), &(&1.id == :admin_emails))
      assert Tab.localized_label(parent) == "Письма"
    end

    test "et locale resolves the parent 'Emails' tab to 'E-kirjad'" do
      Gettext.put_locale(EmailsGettext, "et")

      parent = Enum.find(Emails.admin_tabs(), &(&1.id == :admin_emails))
      assert Tab.localized_label(parent) == "E-kirjad"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(EmailsGettext, "zz")

      parent = Enum.find(Emails.admin_tabs(), &(&1.id == :admin_emails))
      assert Tab.localized_label(parent) == "Emails"
    end
  end
end
