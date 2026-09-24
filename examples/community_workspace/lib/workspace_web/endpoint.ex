defmodule WorkspaceWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :community_workspace

  @session_options [
    store: :cookie,
    key: "_smolbox_workspace",
    signing_salt: "workspace-session",
    same_site: "Strict",
    http_only: true
  ]
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static, at: "/", from: :community_workspace, gzip: false, only: ~w(assets))
  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 17_825_792
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(WorkspaceWeb.Router)
end
