defmodule PhoenixKit.Modules.Emails.Paths do
  @moduledoc "Centralized path helpers for Emails module."
  alias PhoenixKit.Utils.Routes

  @base "/admin/emails"

  def emails_index, do: Routes.path(@base)
  def email_details(id), do: Routes.path("#{@base}/email/#{id}")
  def dashboard, do: Routes.path("#{@base}/dashboard")
  def templates_index, do: Routes.path("#{@base}/templates")
  def template_new, do: Routes.path("#{@base}/templates/new")
  def template_edit(id), do: Routes.path("#{@base}/templates/#{id}/edit")
  def queue, do: Routes.path("#{@base}/queue")
  def blocklist, do: Routes.path("#{@base}/blocklist")
  def settings, do: Routes.path("/admin/settings/emails")
end
