defmodule PhoenixKit.Modules.Emails.TemplateExportVersionTest do
  @moduledoc """
  `default_raw_html_support?/0` against the real `Application` registry,
  rather than whatever version this repo's own `mix.lock` happens to pin.
  Every other test that touches `phoenix_kit_templates`'s loaded version
  either takes `raw_html_supported?` as an explicit argument, or computes its
  own expectation by calling this same function — neither of those can catch
  a bug in what this function *does* on a host, since both would be equally
  wrong under a broken implementation. This file is the one place that
  actually flips the real, loaded version and checks the answer against it.

  `async: false` on purpose: `PhoenixKitEmails.TestSupport.
  PhoenixKitTemplatesVersion` mutates process-global `Application` state for
  the whole VM, so this must never run concurrently with another test module
  that reads `phoenix_kit_templates`'s loaded version.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKitEmails.TestSupport.PhoenixKitTemplatesVersion, as: Version

  test "true once the loaded version is 0.2.0" do
    Version.with_version("0.2.0", fn ->
      assert Application.spec(:phoenix_kit_templates, :vsn) == ~c"0.2.0"
      assert TemplateExport.default_raw_html_support?()
    end)
  end

  test "true above 0.2.0" do
    Version.with_version("0.3.0", fn ->
      assert TemplateExport.default_raw_html_support?()
    end)
  end

  test "false below 0.2.0" do
    Version.with_version("0.1.2", fn ->
      refute TemplateExport.default_raw_html_support?()
    end)
  end

  test "falls back to Application.load/1 when the app starts out unloaded, and answers correctly" do
    original_vsn = Application.spec(:phoenix_kit_templates, :vsn)

    Version.unloaded(fn ->
      assert Application.spec(:phoenix_kit_templates) == nil

      expected = TemplateExport.raw_html_support?(original_vsn)
      assert TemplateExport.default_raw_html_support?() == expected

      # The fallback must have actually reloaded the application, not merely
      # guessed — otherwise this assertion above proves nothing about the
      # fallback path actually running.
      assert Application.spec(:phoenix_kit_templates, :vsn) == original_vsn
    end)
  end

  test "the loaded version is restored after each of the above" do
    # Not a mutation guard on its own, but cheap insurance against a broken
    # restore silently degrading every test that runs after this file.
    assert Application.spec(:phoenix_kit_templates) != nil
  end
end
