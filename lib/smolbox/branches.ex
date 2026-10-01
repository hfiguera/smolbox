defmodule SmolBox.Branches do
  @moduledoc """
  Create managed leaf machines from idle offline bare sources on smolvm 1.19.0, 1.20.2 or 1.22.0.

  Source and child identity, exclusion and capacity are persisted atomically.
  Children run on the source worker and retain a disk dependency on it. Delete
  children first, then explicitly retire their dependencies before stopping or
  deleting the source. Extra backing capacity remains until source deletion and
  host-confirmed file removal through `SmolBox.Branches.release_storage/3`. Nothing is adopted or replayed after an
  uncertain worker response.
  """
  alias SmolBox.{
    BranchClient,
    BranchSpec,
    Error,
    Identity,
    Machines,
    ManagedMachine,
    Runtime,
    Validation
  }

  alias SmolBox.Runtime.Branches, as: BranchRuntime
  alias SmolBox.Runtime.{MachineSession, Session}

  @spec create(SmolBox.runtime(), ManagedMachine.key(), BranchSpec.t()) ::
          {:ok, ManagedMachine.key()} | {:error, Error.t()}
  def create(runtime, source, spec) do
    with :ok <- BranchSpec.validate(spec),
         {:ok, config} <- config(runtime),
         {:ok, parent} <- Machines.inspect(runtime, source) do
      fingerprint = BranchSpec.fingerprint(spec, source, config.fingerprint_key)

      case Machines.inspect(runtime, {parent.scope, spec.id}) do
        {:ok, %{fingerprint: ^fingerprint, branch: %{source: ^source}} = child} ->
          {:ok, ManagedMachine.key(child)}

        {:error, %{category: :not_found}} ->
          accept(config, parent, spec, fingerprint)

        {:ok, _} ->
          Session.error(:identity_conflict, :branch)

        error ->
          error
      end
    end
  end

  defp accept(config, parent, spec, fingerprint) do
    with {:ok, worker} <- MachineSession.worker(config, parent),
         true <- not worker.draining and BranchRuntime.approved?(worker, parent, spec),
         {:ok, name} <- Identity.machine_name(config.namespace),
         {:ok, child} <-
           MachineSession.store(config, :branch_accept, [
             ManagedMachine.key(parent),
             spec,
             fingerprint,
             name,
             worker.capacity,
             config.clock.now()
           ]),
         do: {:ok, ManagedMachine.key(child)},
         else: (
           false -> Session.error(:unsupported_capability, :branch)
           error -> error
         )
  end

  @doc "Read a managed child and its durable `branch` evidence without worker IO."
  @spec fetch(SmolBox.runtime(), ManagedMachine.key()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def fetch(runtime, handle) do
    with {:ok, %{branch: branch} = child} <- Machines.inspect(runtime, handle),
         true <- branch != nil,
         do: {:ok, child},
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc "Wait for ready, held, released or uncertain evidence. Timeout only ends observation."
  @spec await(SmolBox.runtime(), ManagedMachine.key(), non_neg_integer()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def await(runtime, handle, timeout_ms) do
    if Validation.integer?(timeout_ms, 0, 900_000),
      do: wait(runtime, handle, System.monotonic_time(:millisecond) + timeout_ms),
      else: Session.error(:validation, :branch)
  end

  defp wait(runtime, handle, deadline) do
    with {:ok, child} <- fetch(runtime, handle) do
      cond do
        child.branch.state not in [
          :accepted,
          :dispatching,
          :observed,
          :release_pending,
          :release_dispatching
        ] ->
          {:ok, child}

        System.monotonic_time(:millisecond) >= deadline ->
          Session.error(:expired, :branch)

        true ->
          receive do
          after
            25 -> wait(runtime, handle, deadline)
          end
      end
    end
  end

  @doc "Cancel undispatched creation. Dispatched work becomes unknown and retains all resources."
  @spec cancel(SmolBox.runtime(), ManagedMachine.key()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def cancel(runtime, handle) do
    with {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         {:ok, parent} <- Machines.inspect(runtime, child.branch.source) do
      case child.branch.state do
        :accepted ->
          BranchRuntime.advance(config, parent, child, :cancelled)

        state when state in [:dispatching, :observed] ->
          BranchRuntime.advance(config, parent, child, :unknown)

        _ ->
          {:ok, child}
      end
    end
  end

  @doc "Release a held child exactly once. A lost response is never retried; retain the submitted version for deduplication."
  @spec release(SmolBox.runtime(), ManagedMachine.key(), pos_integer()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def release(runtime, handle, version) do
    with true <- Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, _} <- fetch(runtime, handle),
         {:ok, config} <- config(runtime),
         do: MachineSession.store(config, :branch_release, [handle, version, config.clock.now()]),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc """
  Resolve creation after fencing prior requests and confirming worker quiescence.
  `disposition: :keep` needs recorded creation evidence and matching source/child
  observations. Without it, only verified child absence can resolve the request.
  Uncertain release cannot be inferred from the held flag; delete the child before
  using `disposition: :deleted`. Never replays or adopts a child by name.
  """
  @spec resolve(SmolBox.runtime(), ManagedMachine.key(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def resolve(runtime, handle, options) do
    with true <-
           Validation.keys?(options, [:quiesced, :disposition]) and options[:quiesced] == true,
         disposition = options[:disposition],
         true <- disposition in [:keep, :deleted],
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         {:ok, {source, observed}} <-
           MachineSession.io(config, %{parent | operation_deadline_ms: nil}, fn ->
             resolution_evidence(worker.client, parent, child, disposition)
           end),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         do:
           MachineSession.store(config, :branch_resolve, [
             child.branch.source,
             Session.guard(current),
             child.id,
             source,
             observed,
             config.clock.now()
           ]),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc """
  After child deletion, assert that its prior requests are quiescent with
  `quiesced: true`. Verifies absence and retires the source dependency. Extra
  backing allowance remains until `SmolBox.Branches.release_storage/3`. Never deletes anything.
  """
  @spec retire(SmolBox.runtime(), ManagedMachine.key(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def retire(runtime, handle, options) do
    with true <- options == [quiesced: true],
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         {:ok, :absent} <-
           MachineSession.io(config, %{parent | operation_deadline_ms: nil}, fn ->
             BranchClient.absent(worker.client, child.machine_name)
           end),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         do:
           MachineSession.store(config, :branch_retire, [
             child.branch.source,
             Session.guard(current),
             child.id,
             config.clock.now()
           ]),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc "Release backing allowance only after source deletion and host-confirmed removal of retained files."
  @spec release_storage(SmolBox.runtime(), ManagedMachine.key(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def release_storage(runtime, handle, options) do
    with true <- options == [backing_removed: true],
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <-
           MachineSession.io(config, %{parent | operation_deadline_ms: nil}, fn ->
             backing_absent(worker.client, parent, child)
           end),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         do:
           MachineSession.store(config, :branch_release_storage, [
             child.branch.source,
             Session.guard(current),
             child.id,
             config.clock.now()
           ]),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  defp backing_absent(client, parent, child) do
    with {:ok, :absent} <- BranchClient.absent(client, parent.machine_name),
         {:ok, :absent} <- BranchClient.absent(client, child.machine_name),
         do: :ok
  end

  defp resolution_evidence(client, parent, child, disposition) do
    with {:ok, source} <- source_observation(client, parent.machine_name, disposition),
         {:ok, observed} <- resolution_observation(client, child, disposition),
         do: {:ok, {source, observed}}
  end

  defp source_observation(client, name, disposition) do
    case SmolBox.Client.inspect_machine(client, name) do
      {:error, %{category: :not_found}} when disposition == :deleted -> {:ok, :absent}
      result -> result
    end
  end

  defp resolution_observation(client, child, :keep),
    do: BranchClient.inspect_child(client, child, child.branch.spec.hold)

  defp resolution_observation(client, child, :deleted),
    do: BranchClient.absent(client, child.machine_name)

  defp config(runtime) do
    with {:ok, config} <- GenServer.call(Runtime.coordinator(runtime), :config),
         true <- config.managed_machines,
         {:ok, %{managed_branches: 1}} <- Session.store(config, :capabilities, []),
         do: {:ok, config},
         else: (
           {:error, _} = error -> error
           _ -> Session.error(:unsupported_capability, :branch)
         )
  rescue
    _ -> Session.error(:unknown, :runtime)
  catch
    :exit, _ -> Session.error(:unknown, :runtime)
  end
end
