defmodule SmolBox.Runtime.WorkSupervisor do
  @moduledoc false
  use Supervisor
  alias SmolBox.Runtime.Coordinator

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl Supervisor
  def init(config) do
    children = [
      {Task.Supervisor, max_children: config.max_active + 1},
      {Coordinator, {config, self()}}
    ]

    # Coordinator ownership and its execution tasks restart together. A separate
    # notification dispatcher restart does not interrupt this work subtree.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
