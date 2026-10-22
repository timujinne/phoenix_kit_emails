defmodule PhoenixKit.Modules.Emails.Web.RunnerScriptController do
  @moduledoc """
  Serves the SMTP runner script (`priv/smtp_runner/pk-smtp-runner.ps1`) as a download.

  The route sits behind the admin pipeline (a signed-in admin) and the controller adds
  the `emails` permission: the script holds no secret (the site address and the token
  are parameters), but it is part of the module's admin surface and is handed out like
  the rest of it.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Users.Auth.Scope

  @filename "pk-smtp-runner.ps1"

  @doc "The path of the script inside the package."
  @spec script_path() :: String.t()
  def script_path, do: Application.app_dir(:phoenix_kit_emails, "priv/smtp_runner/#{@filename}")

  @doc "Sends the script as an attachment; `403` without the `emails` permission."
  def runner_script(conn, _params) do
    if allowed?(conn) do
      send_script(conn)
    else
      conn
      |> put_resp_content_type("text/plain", "utf-8")
      |> send_resp(403, "Forbidden")
    end
  end

  defp allowed?(conn) do
    case conn.assigns[:phoenix_kit_current_scope] do
      %Scope{} = scope -> Scope.has_module_access?(scope, "emails")
      _ -> false
    end
  end

  defp send_script(conn) do
    case File.read(script_path()) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{@filename}"))
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(404, "The runner script is not part of this build")
    end
  end
end
