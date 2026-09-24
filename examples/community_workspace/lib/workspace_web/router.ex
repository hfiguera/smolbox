defmodule WorkspaceWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {WorkspaceWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'"
    })

    plug(:local_host)
  end

  scope "/", WorkspaceWeb do
    pipe_through(:browser)
    live("/", WorkspaceLive)
    get("/downloads/:id", DownloadController, :show)
  end

  defp local_host(conn, _) do
    if conn.host in ["localhost", "127.0.0.1", "::1"],
      do: conn,
      else:
        conn |> Plug.Conn.send_resp(400, "Use the local workspace address") |> Plug.Conn.halt()
  end
end
