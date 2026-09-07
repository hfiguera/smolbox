defmodule SmolBox.DurableHost.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([SmolBox.DurableHost.Repo],
      strategy: :one_for_one,
      name: SmolBox.DurableHost.Supervisor
    )
  end
end
