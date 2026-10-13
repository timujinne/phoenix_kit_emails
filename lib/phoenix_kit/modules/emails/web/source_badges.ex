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
