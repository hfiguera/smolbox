import Config

# This example's database is explicitly host configured; it never falls back to memory.
database_options =
  case System.get_env("DATABASE_URL") do
    nil ->
      [
        socket_dir: System.fetch_env!("SMOLBOX_DATABASE_SOCKET_DIR"),
        port: String.to_integer(System.get_env("SMOLBOX_DATABASE_PORT", "25432")),
        username: System.get_env("SMOLBOX_DATABASE_USER", "smolbox"),
        database: System.get_env("SMOLBOX_DATABASE_NAME", "smolbox_contract")
      ]

    url ->
      [url: url]
  end

config :smolbox_durable_host, SmolBox.DurableHost.Repo, database_options
