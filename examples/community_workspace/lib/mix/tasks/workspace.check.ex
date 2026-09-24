defmodule Mix.Tasks.Workspace.Check do
  @moduledoc false
  alias SmolBox.DurableHost.Store
  use Mix.Task
  @shortdoc "Read-only configuration, database and worker readiness checks"
  def run(_) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:req)

    unless Application.get_env(:community_workspace, :database_configured),
      do: Mix.raise("Set DATABASE_URL to the dedicated example database")

    {:ok, repo} = Workspace.Repo.start_link()

    result =
      with {:ok, settings} <- Workspace.Settings.load(),
           :ok <- Workspace.Connection.database_ready(),
           {:ok, c} <- Workspace.Settings.build(settings),
           {:ok, _} <- Store.capabilities(c.store),
           {:ok, %{version: "1.17.0"}} <- SmolBox.Client.health(c.client),
           do: SmolBox.Client.readiness(c.client)

    Supervisor.stop(repo)

    case result do
      :ok ->
        Mix.shell().info(
          "Ready: private configuration, migrations, durable store, worker 1.17.0 and readiness. No machine was created or changed."
        )

      {:error, reason} when is_atom(reason) ->
        Mix.raise(
          "Readiness failed: #{reason}. Check DATABASE_URL, run mix workspace.setup, and preserve the original image, configuration and keys."
        )

      _ ->
        Mix.raise(
          "Worker/store readiness failed. Check the configured endpoint, credentials, version 1.17.0, file-transfer cap and native runtime prerequisites. Unavailable does not mean absent."
        )
    end
  end
end
