defmodule SmolBox.Runtime.Branches do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{Backend, ManagedMachine}
  alias SmolBox.Runtime.{MachineSession, Session, WorkerHealth}

  def approved?(worker, parent, spec),
    do:
      worker.runtime_version in ["1.19.0", "1.20.2", "1.22.0"] and
        spec.policy in worker.branch_policies and Target.supports?(worker, parent.spec)

  def supported(_config, %{branch: nil, branch_children: children}) when map_size(children) == 0,
    do: :ok

  def supported(config, _record) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_branches: 1}} -> :ok
      {:ok, _} -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  def run(config, parent) do
    with {:ok, child} <-
           MachineSession.store(config, :fetch, [{parent.scope, parent.active_branch}]) do
      case child.branch.state do
        :accepted -> prepare(config, parent, child)
        :dispatching -> advance(config, parent, child, :unknown)
        :observed -> complete(config, parent, child)
        _ -> MachineSession.write(config, parent, next_due_at_ms: config.clock.now() + 60_000)
      end
    end
  end

  def advance(config, parent, child, change) do
    with {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(parent)),
         do:
           MachineSession.store(config, :branch_advance, [
             ManagedMachine.key(parent),
             Session.guard(current),
             child.id,
             child.branch.state,
             change,
             config.clock.now()
           ])
  end

  defp prepare(config, parent, child) do
    with {:ok, worker} <- MachineSession.worker(config, parent),
         true <- not worker.draining and approved?(worker, parent, child.branch.spec),
         :ok <-
           MachineSession.io(config, parent, fn ->
             preflight(worker, parent, child, config.clock)
           end) do
      dispatch(config, parent, child, worker)
    else
      _ -> advance(config, parent, child, :failed)
    end
  end

  defp dispatch(config, parent, child, worker) do
    with {:ok, pending} <- advance(config, parent, child, :dispatching) do
      response =
        MachineSession.io(config, parent, fn ->
          {:branch_result, Backend.branch_create(Target.connection(worker), parent, pending)}
        end)

      received(config, parent, pending, response)
    end
  end

  defp received(config, parent, child, {:branch_result, {:ok, observed}}) do
    with {:ok, recorded} <- advance(config, parent, child, {:observed, observed}),
         do: complete(config, parent, recorded)
  end

  defp received(config, parent, child, _), do: advance(config, parent, child, :unknown)

  defp preflight(worker, parent, child, clock) do
    with :ok <- WorkerHealth.check(worker, clock),
         {:ok, _} <- Backend.branch_source(Target.connection(worker), parent),
         {:ok, :absent} <- Backend.branch_absent(Target.connection(worker), child.machine_name),
         do: :ok
  end

  defp complete(config, parent, child) do
    with {:ok, worker} <- MachineSession.worker(config, parent),
         {:ok, source} <-
           MachineSession.io(config, parent, fn ->
             completed_evidence(worker, parent, child, config.clock)
           end) do
      advance(config, parent, child, {:complete, source})
    else
      _ -> advance(config, parent, child, :unknown)
    end
  end

  defp completed_evidence(worker, parent, child, clock) do
    with :ok <- WorkerHealth.check(worker, clock),
         {:ok, source} <- Backend.branch_source(Target.connection(worker), parent),
         {:ok, _} <-
           Backend.branch_inspect_child(Target.connection(worker), child, child.branch.spec.hold),
         do: {:ok, source}
  end

  def release(config, child) do
    case child.branch.state do
      :release_pending -> release_preflight(config, child)
      :release_dispatching -> release_advance(config, child, :unknown)
      _ -> MachineSession.write(config, child, next_due_at_ms: config.clock.now() + 60_000)
    end
  end

  defp release_preflight(config, child) do
    with {:ok, worker} <- MachineSession.worker(config, child),
         true <- approved?(worker, child, child.branch.spec),
         {:ok, _} <-
           MachineSession.io(config, child, fn ->
             release_evidence(worker, child, config.clock)
           end),
         {:ok, pending} <- release_advance(config, child, :dispatching) do
      result =
        MachineSession.io(config, pending, fn ->
          {:branch_result, Backend.branch_release(Target.connection(worker), pending)}
        end)

      case result do
        {:branch_result, {:ok, observed}} ->
          release_advance(config, pending, {:complete, observed})

        _ ->
          release_advance(config, pending, :unknown)
      end
    else
      _ -> release_advance(config, child, :unknown)
    end
  end

  defp release_evidence(worker, child, clock) do
    with :ok <- WorkerHealth.check(worker, clock),
         do: Backend.branch_inspect_child(Target.connection(worker), child, true)
  end

  def release_advance(config, child, change) do
    with {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(child)),
         do:
           MachineSession.store(config, :branch_release_advance, [
             ManagedMachine.key(child),
             Session.guard(current),
             child.branch.state,
             change,
             config.clock.now()
           ])
  end
end
