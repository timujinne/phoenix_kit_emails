defmodule PhoenixKitEmails.TestSupport.PhoenixKitTemplatesVersion do
  @moduledoc """
  Test-only helper to exercise `TemplateExport.default_raw_html_support?/0`
  against the real `Application` registry instead of only the version this
  repo's `mix.lock` happens to pin right now. Every test that calls into here
  must live in an `async: false` module: the version it patches is process-
  global for the whole VM, not scoped to one test.

  Restoration is registered via `ExUnit.Callbacks.on_exit/1`, not a plain
  `try/after` in the calling process: `on_exit` runs in ExUnit's own
  supervised callback, so it still fires if the test process itself is
  killed (a test timeout, a linked process crashing) rather than exiting
  normally through the block passed to `with_version/2` or `unloaded/1`.
  Restoration also reloads `:phoenix_kit_templates` from its real, compiled
  `.app` resource on the code path
  (`Application.load/1` with no spec override) rather than replaying a spec
  captured in memory earlier in the test run — a spec captured after an
  already-corrupted prior restore would just make the corruption permanent
  instead of ever recovering from it.
  """

  @app :phoenix_kit_templates

  @doc """
  Runs `fun` with `#{inspect(@app)}` loaded at `vsn` (a version string or
  charlist), restoring it from disk afterward — even if `fun` raises, and
  even if the test process is killed outright.
  """
  @spec with_version(String.t() | charlist(), (-> result)) :: result when result: var
  def with_version(vsn, fun) do
    patch(to_charlist(vsn))
    ExUnit.Callbacks.on_exit(&restore/0)
    fun.()
  end

  @doc """
  Runs `fun` with `#{inspect(@app)}` fully unloaded (`Application.spec/1`
  returns `nil`), restoring it from disk afterward — for testing
  `default_raw_html_support?/0`'s own `Application.load/1` fallback.
  """
  @spec unloaded((-> result)) :: result when result: var
  def unloaded(fun) do
    _ = Application.stop(@app)
    :ok = Application.unload(@app)
    ExUnit.Callbacks.on_exit(&restore/0)
    fun.()
  end

  defp patch(vsn) do
    spec = Application.spec(@app) || raise "#{inspect(@app)} is not loaded"
    _ = Application.stop(@app)
    :ok = Application.unload(@app)
    :ok = :application.load({:application, @app, Keyword.put(spec, :vsn, vsn)})
  end

  defp restore do
    _ = Application.stop(@app)
    _ = Application.unload(@app)
    :ok = Application.load(@app)
    _ = Application.ensure_all_started(@app)
  end
end
