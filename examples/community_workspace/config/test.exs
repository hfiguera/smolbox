import Config
config :community_workspace, WorkspaceWeb.Endpoint, server: false
config :community_workspace, :connect_runtime, false
config :community_workspace, Workspace.Repo, pool: Ecto.Adapters.SQL.Sandbox
config :logger, level: :error
