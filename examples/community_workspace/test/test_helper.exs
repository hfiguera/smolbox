ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Workspace.Repo, :auto)

Ecto.Migrator.run(Workspace.Repo, Workspace.Migrations.paths(), :up, all: true, log: false)
Ecto.Adapters.SQL.Sandbox.mode(Workspace.Repo, :manual)
