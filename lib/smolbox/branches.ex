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
    BranchSpec,
    Error,
    Identity,
    Machines,
    ManagedMachine,
    Runtime,
    Validation
  }

  alias SmolBox.Runtime.Branches, as: BranchRuntime

  alias SmolBox.Runtime.{
    BranchObservation,
    MachineSession,
    NativeBranchBacking,
    NativeCollectedBranchPublication,
    NativeDeletedBranchResolution,
    NativePartialBranchCleanup,
    NativePartialBranchCollection,
    NativePartialBranchDisposal,
    NativePartialBranchRetirement,
    NativeReadyBranchResolution,
    NativeResolution,
    NativeUnbootedBranchRetirement,
    Session,
    Target
  }

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
  observations. Embedded initial creation may explicitly hand off an already
  completed original initialization/release under a fresh finite deadline; it
  never replays boot, initialization or activation. Without that original result,
  only verified child absence can resolve the request.
  Uncertain release cannot be inferred from the held flag; delete the child before
  using `disposition: :deleted`. Embedded resolution can also consume protected
  pre-SDK retirement proof for a never-created child with an unchanged source
  head. An exact original published child that never entered boot can instead be
  selected by positive native evidence, accept a durable disposal request, and
  complete with typed disposal proof plus a fresh source observation. The same
  helper/controller fence covers selection, acceptance and final paired commit.
  Retried accepted intent preserves its original identity and observes completion
  before offering any still-unentered one-shot dispatch. Never replays SDK deletion
  or adopts a child by name. An acknowledged pre-handoff collection selects its
  distinct partial-disposal action instead, preserving collection history and
  requiring original disposal proof plus fresh source observation. An unacknowledged
  collection cannot fall through to other disposal or retirement paths.
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
         do: resolve_child(config, runtime, child, disposition),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  defp resolve_child(
         config,
         runtime,
         %{branch: %{native_authority: %{partial_disposal: %{cleanup: cleanup}}}} = child,
         :deleted
       )
       when not is_nil(cleanup),
       do:
         NativePartialBranchCleanup.run(
           config,
           Runtime.coordinator(runtime),
           child,
           child.version
         )

  defp resolve_child(
         config,
         runtime,
         %{branch: %{native_authority: %{partial_collection: collection}}} = child,
         :deleted
       )
       when not is_nil(collection),
       do:
         NativePartialBranchDisposal.run(
           config,
           Runtime.coordinator(runtime),
           child,
           child.version
         )

  defp resolve_child(config, runtime, %{branch: %{native_authority: authority}} = child, :deleted)
       when not is_nil(authority),
       do: NativeDeletedBranchResolution.run(config, Runtime.coordinator(runtime), child)

  defp resolve_child(
         config,
         runtime,
         %{branch: %{native_authority: %{disposal: nil, release: nil}}} = child,
         :keep
       ),
       do: NativeReadyBranchResolution.run(config, Runtime.coordinator(runtime), child)

  defp resolve_child(config, runtime, child, disposition) do
    with {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         do:
           explicit(config, runtime, parent, child, worker, :branch_resolve, fn pinned ->
             BranchObservation.resolution(pinned, parent, child, disposition)
           end)
  end

  @doc """
  Explicitly collect the original embedded child of an uncertain creation.
  Requires its expected version and `quiesced: true`. The accepted request is
  durable before helper IO; an exact saved acknowledgement returns without IO.
  Collection alone leaves creation unknown and retains all reservations,
  dependencies and disks. It never initializes, deletes or adopts a child, or
  releases backing. Historical acknowledgement reads return the current record,
  including a later separately acknowledged disposal, without helper IO.
  """
  @spec collect_partial(SmolBox.runtime(), ManagedMachine.key(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def collect_partial(runtime, handle, version, options) do
    with true <-
           options == [quiesced: true] and Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         :ok <- require_partial_native(child),
         do:
           NativePartialBranchCollection.run(
             config,
             Runtime.coordinator(runtime),
             child,
             version
           ),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc """
  Publish material retained by the original embedded owner after collection.
  Requires an expected child version and `quiesced: true`. Saves the full creation
  request before IO, then atomically records the material proof beside a separate
  fresh source observation. Both managed states remain unknown and all capacity,
  dependencies and backing stay reserved. This does not boot, initialize, release,
  dispose or adopt a child. Saved acknowledgements return without helper IO,
  including after a separately completed creation or disposal.
  """
  @spec publish_collected(SmolBox.runtime(), ManagedMachine.key(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def publish_collected(runtime, handle, version, options) do
    with true <-
           options == [quiesced: true] and
             Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         :ok <- require_partial_native(child),
         do:
           NativeCollectedBranchPublication.run(
             config,
             Runtime.coordinator(runtime),
             child,
             version
           ),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc """
  Dispose an uncertain original embedded child after acknowledged collection.
  Requires its expected version and `quiesced: true`. The distinct request is
  saved before native IO. Completion requires the original disposal proof and
  fresh source observation; only ordinary child capacity retires. Source
  dependency and extra backing remain charged. Exact saved results return without
  helper IO. An uncertain retry never automatically replays native deletion.
  """
  @spec dispose_partial(SmolBox.runtime(), ManagedMachine.key(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def dispose_partial(runtime, handle, version, options) do
    with true <-
           options == [quiesced: true] and
             Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         :ok <- require_partial_native(child),
         do:
           NativePartialBranchDisposal.run(config, Runtime.coordinator(runtime), child, version),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  @doc """
  Clean residual files of an uncertain, collected original embedded child.

  Requires an accepted original disposal, its expected current version and
  `quiesced: true`. Qualifies the original disposal before accepting fresh cleanup.
  An already terminal disposal is recorded with fresh source observation instead.
  Only a positive residual candidate permits saving a separate cleanup request.
  Its original cached/protected removal grant may remove the child subtree;
  this never retries SDK deletion. Matching cleanup and fresh source observation
  commit disposal and release only ordinary child capacity. Source dependency and
  extra backing remain charged. Retries preserve the exact accepted request.
  If cleanup definitively did not dispatch, a helper with the negotiated optional
  resolution capability may acknowledge that original disposal made cleanup
  unnecessary. This distinct proof and fresh source observation close the same
  saved action without claiming removal. Missing history retains pending state;
  no removal/SDK fallback follows resolution. Saved acknowledgements return
  without helper IO, including the version that completed the action.
  """
  @spec cleanup_partial(SmolBox.runtime(), ManagedMachine.key(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def cleanup_partial(runtime, handle, version, options) do
    with true <-
           options == [quiesced: true] and
             Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         :ok <- require_partial_native(child),
         do: NativePartialBranchCleanup.run(config, Runtime.coordinator(runtime), child, version),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  defp require_partial_native(%{
         branch: %{native_authority: %SmolBox.Embedded.NativeBranchAuthority{}}
       }),
       do: :ok

  defp require_partial_native(_), do: Session.error(:unsupported_capability, :branch)

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
         do: retire_child(config, runtime, child),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  defp retire_child(
         config,
         runtime,
         %{
           branch: %{
             native_authority: %{
               partial_disposal: %{proof: %SmolBox.Embedded.PartialBranchDisposal{}}
             }
           }
         } = child
       ),
       do: NativePartialBranchRetirement.run(config, Runtime.coordinator(runtime), child)

  defp retire_child(
         config,
         runtime,
         %{
           branch: %{
             native_authority: %{disposal: %{proof: %SmolBox.Embedded.UnbootedBranchDisposal{}}}
           }
         } = child
       ),
       do: NativeUnbootedBranchRetirement.run(config, Runtime.coordinator(runtime), child)

  defp retire_child(config, runtime, child) do
    with {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         do:
           explicit(config, runtime, parent, child, worker, :branch_retire, fn pinned ->
             BranchObservation.retirement(pinned, child)
           end)
  end

  @doc "Release backing allowance only after source deletion and host-confirmed removal of retained files."
  @spec release_storage(SmolBox.runtime(), ManagedMachine.key(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def release_storage(runtime, handle, options) do
    with true <- options == [backing_removed: true],
         {:ok, config} <- config(runtime),
         {:ok, child} <- fetch(runtime, handle),
         do: release_backing(config, runtime, child),
         else: (
           false -> Session.error(:validation, :branch)
           error -> error
         )
  end

  defp release_backing(config, runtime, %{branch: %{native_authority: authority}} = child)
       when not is_nil(authority),
       do: NativeBranchBacking.run(config, Runtime.coordinator(runtime), child)

  defp release_backing(config, runtime, child) do
    with {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         do:
           explicit(config, runtime, parent, child, worker, :branch_release_storage, fn pinned ->
             BranchObservation.storage_release(pinned, parent, child)
           end)
  end

  defp explicit(config, runtime, parent, child, worker, operation, observe) do
    deadline =
      if worker.kind == :embedded,
        do:
          System.monotonic_time(:millisecond) +
            min(Target.connection(worker).budget.timeout_ms, 30_000)

    NativeResolution.run(
      config,
      Runtime.coordinator(runtime),
      parent,
      worker,
      if(worker.kind == :embedded, do: {:ordinary_branch, operation}, else: operation),
      fn pinned ->
        finish_explicit(config, parent, child, operation, fn -> observe.(pinned) end, deadline)
      end,
      deadline
    )
  end

  defp finish_explicit(config, parent, child, operation, observe, deadline) do
    with :ok <- within_deadline(deadline),
         {:ok, evidence} <-
           MachineSession.io(config, %{parent | operation_deadline_ms: nil}, observe),
         :ok <- within_deadline(deadline),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         :ok <- within_deadline(deadline),
         do:
           MachineSession.store(
             config,
             operation,
             [child.branch.source, Session.guard(current), child.id] ++
               evidence ++ [config.clock.now()]
           )
  end

  defp within_deadline(nil), do: :ok

  defp within_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline,
      do: :ok,
      else: Session.error(:expired, :branch)
  end

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
