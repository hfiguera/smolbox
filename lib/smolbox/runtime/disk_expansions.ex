defmodule SmolBox.Runtime.DiskExpansions do
  @moduledoc false
  alias SmolBox.{Client, DiskExpansion, Error, ManagedMachine}
  alias SmolBox.Runtime.MachineSession, as: Machines
  alias SmolBox.Runtime.{Session, WorkerHealth}

  def supported(config) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_disk_expansion: 1}} -> :ok
      {:ok, _} -> Session.error(:unsupported_capability, :expand_disks)
      error -> error
    end
  end

  def run(config, m) do
    with :ok <- supported(config) do
      case m.disk_expansions[m.active_expansion].state do
        :pending -> dispatch(config, m)
        :dispatching -> unknown(config, m, %Error{category: :unknown, operation: :expand_disks})
        :unknown -> Machines.write(config, m, next_due_at_ms: config.clock.now() + 60_000)
      end
    end
  end

  def advance(config, m, outcome) do
    r = m.disk_expansions[m.active_expansion]

    with {:ok, current} <- Machines.claim(config, ManagedMachine.key(m)) do
      Machines.store(config, :expansion_advance, [
        ManagedMachine.key(m),
        Session.guard(current),
        r.id,
        r.state,
        outcome,
        config.clock.now()
      ])
    end
  end

  defp dispatch(config, m) do
    with {:ok, worker} <- Machines.worker(config, m),
         true <- worker.runtime_version == "1.20.2",
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         {:ok, observed} <-
           Machines.io(config, m, fn ->
             Client.inspect_machine(worker.client, m.machine_name)
           end),
         true <- observed.state in [:created, :stopped] and DiskExpansion.matches?(m, observed),
         {:ok, intent} <- advance(config, m, :dispatch) do
      result = Machines.io(config, intent, fn -> grow_and_observe(worker, intent) end)

      received(config, intent, result)
    else
      {:error, error} -> unknown(config, m, error)
      _ -> unknown(config, m, %Error{category: :identity_conflict, operation: :expand_disks})
    end
  end

  defp grow_and_observe(worker, intent) do
    r = intent.disk_expansions[intent.active_expansion]

    with {:ok, _} <-
           Client.expand_disks(worker.client, DiskExpansion.expected(intent),
             storage_gb: r.storage_gb,
             overlay_gb: r.overlay_gb
           ),
         do: Client.inspect_machine(worker.client, intent.machine_name)
  end

  defp received(config, m, {:ok, observed}) do
    case advance(config, m, {:complete, observed}) do
      {:error, %Error{category: :identity_conflict} = error} -> unknown(config, m, error)
      result -> result
    end
  end

  defp received(config, m, {:error, error}), do: unknown(config, m, error)
  defp unknown(config, m, error), do: advance(config, m, {:unknown, error})
end
