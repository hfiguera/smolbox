defmodule WorkspaceWeb.DownloadController do
  use Phoenix.Controller, formats: [:html]

  def show(conn, %{"id" => id}) do
    case Workspace.Workspaces.download(id) do
      {:ok, filename, bytes} ->
        send_download(conn, {:binary, bytes},
          filename: filename,
          content_type: "application/octet-stream"
        )

      _ ->
        conn
        |> put_status(409)
        |> text("The download is not available. Check the collection result in your workspace.")
    end
  end
end
