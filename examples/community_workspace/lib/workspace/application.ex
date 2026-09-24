defmodule Workspace.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    database =
      if Application.get_env(:community_workspace, :database_configured),
        do: [Workspace.Repo],
        else: []

    children =
      database ++
        [
          {Phoenix.PubSub, name: Workspace.PubSub},
          {Task.Supervisor, name: Workspace.Tasks},
          {DynamicSupervisor, name: Workspace.Runtimes, strategy: :one_for_one},
          {Registry, keys: :unique, name: Workspace.TerminalRegistry},
          {DynamicSupervisor, name: Workspace.Terminals, strategy: :one_for_one},
          Workspace.Connection,
          WorkspaceWeb.Endpoint
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Workspace.Supervisor)
  end

  def config_change(changed, _new, removed),
    do: WorkspaceWeb.Endpoint.config_change(changed, removed)
end
