defmodule SmolBox.Runtime.WorkSupervisor do
  @moduledoc false
  use Supervisor
  alias SmolBox.Runtime.{Coordinator, KubernetesSupport}

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl Supervisor
  def init(config) do
    config = %{
      config
      | terminal_table: :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    }

    recovery_tasks = length(KubernetesSupport.targets(config))

    children = [
      # Execution observers, maintenance, a scan and each Kubernetes recovery.
      {Task.Supervisor, max_children: config.max_active + 2 + recovery_tasks},
      {Coordinator, {config, self()}}
    ]

    # Coordinator ownership and its execution tasks restart together. A separate
    # notification dispatcher restart does not interrupt this work subtree.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
