import Config

config :community_workspace, ecto_repos: [Workspace.Repo]

config :community_workspace, Workspace.Repo,
  pool_size: 8,
  log: false,
  show_sensitive_data_on_connection_error: false

config :community_workspace, WorkspaceWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: WorkspaceWeb.ErrorHTML], layout: false],
  pubsub_server: Workspace.PubSub,
  live_view: [signing_salt: "workspace-live"],
  server: true

config :phoenix, :json_library, Jason
config :logger, :console, format: "$time $level $message\n"
config :logger, level: :warning
import_config "#{config_env()}.exs"
