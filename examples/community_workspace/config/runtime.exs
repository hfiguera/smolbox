import Config

home = System.get_env("SMOLBOX_WORKSPACE_HOME", Path.expand(".workspace"))
port = String.to_integer(System.get_env("PORT", "4000"))
config :community_workspace, :home, home

secret =
  case File.read(Path.join(home, "web.key")) do
    {:ok, bytes} when byte_size(bytes) == 64 -> Base.encode64(bytes)
    _ -> Base.encode64(:crypto.strong_rand_bytes(64))
  end

config :community_workspace, WorkspaceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  check_origin: ["//localhost:#{port}", "//127.0.0.1:#{port}"],
  secret_key_base: secret

if database = System.get_env("DATABASE_URL") do
  config :community_workspace, Workspace.Repo, url: database
  config :community_workspace, :database_configured, true
else
  config :community_workspace, :database_configured, false
end
