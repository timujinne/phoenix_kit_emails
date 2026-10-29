defmodule PhoenixKit.Modules.Emails.Web.SourceBadges do
  @moduledoc """
  Says which layer built a logged message (#48): a host file override or a
  default shipped by core or a module (`"db"` appears only on log rows written
  before the database layer was retired).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKit.Modules.Emails.Gettext

  attr(:log, :any, required: true)

  @doc """
  Says which layer built a logged message (#48): a host file override, a module
  default, or (on old rows) the retired database template.
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
    do:
      gettext(
        "This message was built from a template stored in the database (a layer since retired)."
      )

  defp log_message("file"),
    do: gettext("This message was built from a file override supplied by the host.")

  defp log_message(_module),
    do:
      gettext(
        "This message was built from a default: one shipped by core or a module, or supplied by the host in code."
      )
end
