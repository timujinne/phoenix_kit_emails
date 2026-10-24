defmodule PhoenixKit.Modules.Emails.Web.SourceBadges do
  @moduledoc """
  Says which layers an active template row hides (#48): a host file override
  and/or a default shipped by core or a module.

  `variant={:badge}` is a compact tag for a list row; `variant={:notice}` spells
  the sentences out for the editor. Nothing is drawn when the row hides nothing
  or when `sources` is absent.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  alias PhoenixKit.Modules.Emails.Paths
  alias PhoenixKit.Modules.Emails.TemplateSources

  attr(:template, :any, required: true)
  attr(:sources, :any, default: nil)
  attr(:variant, :atom, default: :badge, values: [:badge, :notice])

  def source_badges(assigns) do
    assigns = assign(assigns, :layers, layers(assigns.template, assigns.sources))

    ~H"""
    <%= if @layers != [] do %>
      <%= if @variant == :notice do %>
        <div class={["alert alert-soft alert-vertical text-sm", notice_class(@layers)]}>
          <p :for={layer <- @layers}>{message(layer)}</p>
        </div>
      <% else %>
        <div class="flex flex-wrap gap-1">
          <span
            :for={layer <- @layers}
            tabindex="0"
            aria-label={message(layer)}
            title={message(layer)}
            class={["badge badge-soft badge-xs h-auto", badge_class(layer)]}
          >
            {label(layer)}
          </span>
        </div>
      <% end %>
    <% end %>
    """
  end

  attr(:log, :any, required: true)
  attr(:template_exists?, :boolean, default: false)

  @doc """
  Says which layer built a logged message (#48): the database row (with a link
  to it while it still exists), a host file override, or a module default.
  Nothing is drawn for a log without a `template_source`.
  """
  def log_source(assigns) do
    ~H"""
    <span :if={@log.template_source} class="inline-flex items-center gap-2">
      <span
        tabindex="0"
        aria-label={log_message(@log.template_source)}
        title={log_message(@log.template_source)}
        class={["badge badge-soft badge-sm h-auto", log_badge_class(@log.template_source)]}
      >
        {log_label(@log.template_source)}
      </span>
      <.link
        :if={@log.template_source == "db" and @log.template_uuid && @template_exists?}
        navigate={Paths.template_edit(@log.template_uuid)}
        class="text-xs text-blue-600 hover:underline"
      >
        {gettext("Open template")}
      </.link>
    </span>
    """
  end

  defp log_badge_class("db"), do: "badge-primary"
  defp log_badge_class("file"), do: "badge-warning"
  defp log_badge_class(_module), do: "badge-info"

  defp log_label("db"), do: gettext("Database template")
  defp log_label("file"), do: gettext("File override")
  defp log_label(_module), do: gettext("Default template")

  defp log_message("db"),
    do: gettext("This message was built from a template stored in the database.")

  defp log_message("file"),
    do: gettext("This message was built from a file override supplied by the host.")

  defp log_message(_module),
    do:
      gettext(
        "This message was built from a default: one shipped by core or a module, or supplied by the host in code."
      )

  defp layers(template, %{overrides: _, defaults: _} = sources),
    do: TemplateSources.layers(template, sources)

  defp layers(_template, _sources), do: []

  # A file override is the host's own work that an active row silently
  # overrides: worth a warning. A default is what ships with core or a module
  # and is expected to be overridden: information only.
  defp badge_class(:file), do: "badge-warning"
  defp badge_class({:default, _owner}), do: "badge-info"

  defp notice_class(layers), do: if(:file in layers, do: "alert-warning", else: "alert-info")

  defp label(:file), do: gettext("File override shadowed")
  defp label({:default, _owner}), do: gettext("Default shadowed")

  defp message(:file),
    do: gettext("A file override exists for this name — this active row shadows it.")

  defp message({:default, nil}),
    do: gettext("A built-in default exists for this name — this active row shadows it.")

  defp message({:default, owner}) do
    gettext("A default supplied by %{module} exists for this name — this active row shadows it.",
      module: module_name(owner)
    )
  end

  defp module_name(module) do
    module |> Module.split() |> List.last()
  rescue
    ArgumentError -> inspect(module)
  end
end
