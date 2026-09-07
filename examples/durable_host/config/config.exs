import Config

config :smolbox_durable_host, ecto_repos: [SmolBox.DurableHost.Repo]

config :smolbox_durable_host, SmolBox.DurableHost.Repo,
  pool_size: 8,
  log: false,
  show_sensitive_data_on_connection_error: false
