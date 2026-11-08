defmodule SmolBox.Runtime.DiskExpansions do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{Backend, DiskExpansion, Error, ManagedMachine}
  alias SmolBox.Runtime.MachineSession, as: Machines
  alias SmolBox.Runtime.{Session, WorkerHealth}
  alias SmolBox.Store.ExpansionOps

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

  def resolution_observation(%{kind: :embedded} = worker, intent, :stopped) do
    reference = Target.connection(worker, intent)
    deadline = System.monotonic_time(:millisecond) + reference.budget.timeout_ms

    with {:ok, grown} <- Backend.qualify_growth(reference, true),
         {:ok, preview} <- resolution_preview(intent, grown),
         remaining = deadline - System.monotonic_time(:millisecond),
         true <- remaining > 0 do
      worker
      |> Target.connection(preview)
      |> Backend.bounded(timeout_ms: remaining)
      |> Backend.inspect_machine(intent.machine_name)
    else
      false -> Session.error(:expired, :expand_disks)
      {:error, error} -> {:error, %{error | operation: :expand_disks}}
    end
  end

  def resolution_observation(worker, intent, _disposition),
    do: Backend.inspect_machine(Target.connection(worker, intent), intent.machine_name)

  def resolution_preview(intent, grown) do
    r = intent.disk_expansions[intent.active_expansion]
    ExpansionOps.advance(intent, r.id, :unknown, {:resolve, grown}, intent.updated_at_ms)
  end

  defp dispatch(config, m) do
    with {:ok, worker} <- Machines.worker(config, m),
         true <- Target.supports_feature?(worker, :disk_growth),
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         {:ok, observed} <-
           Machines.io(config, m, fn ->
             Backend.inspect_machine(Target.connection(worker, m), m.machine_name)
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

    with {:ok, grown} <-
           Backend.expand_disks(Target.connection(worker, intent), DiskExpansion.expected(intent),
             storage_gb: r.storage_gb,
             overlay_gb: r.overlay_gb
           ),
         do: observe_grown(worker, intent, grown)
  end

  defp observe_grown(%{kind: :embedded} = worker, intent, grown) do
    r = intent.disk_expansions[intent.active_expansion]
    # This is a local validated preview for the follow-up reference. Durable
    # intent remains dispatching until the subsequent observation is committed.
    with {:ok, preview} <-
           ExpansionOps.advance(
             intent,
             r.id,
             :dispatching,
             {:complete, grown},
             intent.updated_at_ms
           ),
         do: Backend.inspect_machine(Target.connection(worker, preview), intent.machine_name)
  end

  defp observe_grown(worker, intent, _grown),
    do: Backend.inspect_machine(Target.connection(worker, intent), intent.machine_name)

  defp received(config, m, {:ok, observed}) do
    case advance(config, m, {:complete, observed}) do
      {:error, %Error{category: :identity_conflict} = error} -> unknown(config, m, error)
      result -> result
    end
  end

  defp received(config, m, {:error, error}), do: unknown(config, m, error)
  defp unknown(config, m, error), do: advance(config, m, {:unknown, error})
end
