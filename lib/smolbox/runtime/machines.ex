defmodule SmolBox.Runtime.Machines do
  alias SmolBox.Runtime.Target
  @moduledoc false
  alias SmolBox.{Backend, Error, Identity, Machine, ManagedMachine}
  alias SmolBox.Backend.Assignment
  alias SmolBox.Embedded.Identity, as: NativeIdentity
  alias SmolBox.Runtime.Branches
  alias SmolBox.Runtime.Checkpoints
  alias SmolBox.Runtime.DiskExpansions
  alias SmolBox.Runtime.{ExecutionSupport, Exports}
  alias SmolBox.Runtime.{Session, VolumeAccess, WorkerHealth}

  defdelegate store(config, operation, arguments), to: SmolBox.Runtime.MachineSession

  def run(config, key, eligible) do
    Session.safe(fn ->
      with {:ok, record} <- claim(config, key),
           config = Target.pin_config(config, record, eligible),
           :ok <- port_support(config, record.spec.ports),
           :ok <- ExecutionSupport.check(config, record.spec),
           :ok <- Branches.supported(config, record) do
        route(config, record, eligible)
      end
    end)
  end

  def port_support(_config, []), do: :ok

  def port_support(config, _ports) do
    case Session.store(config, :capabilities, []) do
      {:ok, %{managed_ports: 1}} -> :ok
      {:ok, _unsupported} -> Session.error(:unsupported_capability, :machine)
      error -> error
    end
  end

  defdelegate claim(config, key), to: SmolBox.Runtime.MachineSession
  defdelegate write(config, record, changes), to: SmolBox.Runtime.MachineSession

  defp route(config, %{operation: :expand_disks} = record, _eligible),
    do: DiskExpansions.run(config, record)

  defp route(config, %{operation: :branch} = record, _eligible),
    do: Branches.run(config, record)

  defp route(config, %{operation: :branch_child} = record, _eligible),
    do: write(config, record, next_due_at_ms: config.clock.now() + 60_000)

  defp route(config, %{operation: :branch_release} = record, _eligible),
    do: Branches.release(config, record)

  defp route(config, %{operation: :capture} = record, _eligible),
    do: Checkpoints.run(config, record)

  defp route(config, %{operation: :export} = record, _eligible),
    do: Exports.run(config, record)

  # An older controller may have accepted and attached volumes before this
  # check existed. Keep that record cancellable and reserve no machine resources.
  defp route(config, %{state: :accepted, volume_worker_id: id} = record, eligible)
       when is_binary(id) do
    target = Enum.find(config.workers, &(Target.id(&1) == id))

    case VolumeAccess.mount_budget(target, record.spec) do
      :ok ->
        reserve(config, record, eligible)

      {:error, error} ->
        unassigned_conflict(config, record, %{error | operation: :prepare_artifact})
    end
  end

  defp route(config, %{state: :accepted} = record, eligible),
    do: reserve(config, record, eligible)

  defp route(config, %{state: :conflict, worker_id: nil} = record, _eligible),
    do: write(config, record, next_due_at_ms: config.clock.now() + 60_000)

  defp route(_config, %{active_execution: key} = record, _eligible) when not is_nil(key),
    do: {:ok, record}

  defp route(_config, %{state: :deleted} = record, _eligible), do: {:ok, record}
  defp route(config, %{phase: :pending} = record, _eligible), do: dispatch(config, record)
  defp route(config, %{phase: :prepared} = record, _eligible), do: dispatch(config, record)
  defp route(config, record, _eligible), do: observe(config, record)

  defp reserve(config, record, eligible) do
    workers =
      Enum.filter(
        config.workers,
        &(Target.id(&1) in eligible and
            record.volume_worker_id in [nil, Target.id(&1)] and
            Target.supports?(&1, record.spec))
      )

    result =
      Enum.reduce_while(workers, {:ok, record}, fn worker, _previous ->
        with %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
             :ok <- Target.qualify(worker, record.spec),
             {:ok, current} <- claim(config, ManagedMachine.key(record)),
             {:ok, name} <- Identity.machine_name(config.namespace),
             {:ok, allocation} <- Target.allocation_record(worker, current, name),
             {:ok, reserved} <-
               store(config, :reserve, [
                 ManagedMachine.key(record),
                 Session.guard(current),
                 allocation,
                 config.clock.now()
               ]) do
          {:halt, dispatch(config, reserved)}
        else
          {:error, %Error{category: :admission_exhausted}} ->
            {:cont, {:ok, record}}

          {:error, %Error{category: :port_conflict} = error} ->
            {:halt, unassigned_conflict(config, record, error)}

          {:error,
           %Error{operation: :qualify_creation, evidence: :not_dispatched, category: category} =
               error}
          when category in [:unsupported_capability, :validation] ->
            {:halt, unassigned_conflict(config, record, %{error | operation: :prepare_artifact})}

          {:error, _error} = error ->
            {:halt, error}

          _unready ->
            {:cont, {:ok, record}}
        end
      end)

    defer_admission(config, result)
  end

  defp unassigned_conflict(config, record, error) do
    fresh_write(config, record,
      state: :conflict,
      operation: nil,
      phase: nil,
      last_error: error,
      next_due_at_ms: config.clock.now() + 60_000
    )
  end

  defp defer_admission(config, {:ok, %{state: :accepted} = record}),
    do: fresh_write(config, record, next_due_at_ms: config.clock.now() + 1000)

  defp defer_admission(_config, result), do: result

  defp dispatch(
         config,
         %{phase: :pending, operation: :create, spec: %{artifact: %{"kind" => "registry"}}} =
           record
       ),
       do: prepare(config, record)

  defp dispatch(config, record) do
    with {:ok, worker} <- worker(config, record),
         true <-
           record.operation in [:stop, :delete] or Target.supports?(worker, record.spec),
         :ok <- volume_policy(config, record),
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         :ok <- verify_before(config, record, worker),
         {:ok, current} <- claim(config, ManagedMachine.key(record)),
         true <- current.phase in [:pending, :prepared] and current.active_execution == nil,
         {:ok, intent} <-
           write(config, current,
             phase: :dispatching,
             operation_deadline_ms:
               current.operation_deadline_ms ||
                 config.clock.now() + record.spec.profile.preparation_ms
           ) do
      result = io(config, intent, fn -> mutate(worker, intent) end)
      complete_response(config, intent, result)
    else
      {:error, error} ->
        failed_observation(config, record, error)

      _unready ->
        failed_observation(config, record, %Error{
          category: :unsupported_capability,
          operation: :worker
        })
    end
  end

  defp volume_policy(_, %{operation: op}) when op in [:stop, :delete], do: :ok
  defp volume_policy(config, record), do: VolumeAccess.approved(config, record.spec)

  defp prepare(config, record) do
    with {:ok, worker} <- worker(config, record),
         true <- Target.supports?(worker, record.spec),
         :ok <- volume_policy(config, record),
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         {:ok, current} <- claim(config, ManagedMachine.key(record)),
         true <- current.phase == :pending and current.operation == :create,
         {:ok, intent} <-
           write(config, current,
             phase: :preparing,
             operation_deadline_ms: config.clock.now() + record.spec.profile.preparation_ms
           ) do
      result = io(config, intent, fn -> warm(worker, intent) end)

      prepared(config, intent, result)
    else
      {:error, error} ->
        failed_observation(config, record, error)

      _unready ->
        failed_observation(config, record, %Error{
          category: :unsupported_capability,
          operation: :source
        })
    end
  end

  defp warm(worker, intent) do
    with {:ok, source} <- SmolBox.Source.from_artifact(intent.spec.artifact),
         {:ok, credentials} <-
           SmolBox.RegistryCredentials.resolve(worker.registry_credentials, source),
         do: Backend.prepare_artifact(Target.connection(worker, intent), source, credentials)
  end

  defp prepared(config, record, {:ok, %SmolBox.ArtifactPreparation{} = result}) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         true <- current.phase == :preparing and current.operation == :create,
         {:ok, saved} <- write(config, current, preparation: result, phase: :prepared) do
      dispatch(config, saved)
    else
      false -> Session.error(:stale_version, :machine)
      error -> error
    end
  end

  defp prepared(config, record, {:error, %{evidence: :not_dispatched} = error}),
    do:
      fresh_write(config, record,
        state: :unknown,
        phase: :uncertain,
        last_error: error,
        next_due_at_ms: config.clock.now() + 60_000
      )

  defp prepared(config, record, {:error, error}), do: uncertain(config, record, error)

  defp prepared(config, record, _invalid),
    do: uncertain(config, record, %Error{category: :protocol, operation: :prepare_artifact})

  defp verify_before(_config, %{operation: :create, created_machine: nil}, _worker), do: :ok

  defp verify_before(config, record, worker) do
    with {:ok, observed} <-
           io(config, record, fn ->
             Backend.inspect_machine(Target.connection(worker, record), record.machine_name)
           end),
         true <-
           record.created_machine != nil and
             SmolBox.DiskExpansion.matches?(record, observed) do
      :ok
    else
      false -> Session.error(:identity_conflict, :inspect)
      error -> error
    end
  end

  defp mutate(worker, %{operation: :create} = record) do
    with {:ok, spec} <- Target.machine_spec(worker, record.spec, record.machine_name),
         do: create(worker, record, %{spec | mounts: record.mounts})
  end

  defp mutate(
         %{kind: :http} = worker,
         %{operation: :start, branch: nil, spec: %{branch_static_egress: true}} = record
       ) do
    Backend.start_static_branch_source(
      Target.connection(worker, record),
      record.machine_name,
      record.spec.profile.network
    )
  end

  defp mutate(
         worker,
         %{operation: :start, spec: %{checkpointable: true, profile: profile}} = record
       )
       when profile.network != :offline,
       do:
         Backend.start_https_branch_source(
           Target.connection(worker, record),
           record.machine_name,
           profile.network
         )

  defp mutate(worker, %{operation: :start, spec: %{checkpointable: true}} = record),
    do: Backend.start_checkpointable(Target.connection(worker, record), record.machine_name)

  defp mutate(worker, record),
    do: apply(Backend, record.operation, [Target.connection(worker, record), record.machine_name])

  defp create(worker, record, %{source: %SmolBox.Source{kind: :registry} = source} = spec) do
    with {:ok, credentials} <-
           SmolBox.RegistryCredentials.resolve(worker.registry_credentials, source),
         do:
           Backend.create_prepared(
             Target.connection(worker, record),
             spec,
             record.preparation,
             credentials
           )
  end

  defp create(worker, %{spec: %{checkpointable: true}} = record, %{network: network} = spec)
       when network != :offline,
       do: Backend.create(Target.connection(worker, record), spec, branch_https: true)

  defp create(worker, record, spec), do: Backend.create(Target.connection(worker, record), spec)

  defp complete_response(config, record, {:ok, %Machine{} = observed}) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         creation = current.created_machine || if(current.operation == :create, do: observed),
         true <-
           creation != nil and
             if(current.created_machine,
               do: SmolBox.DiskExpansion.matches?(current, observed),
               else: Machine.same_incarnation?(creation, observed)
             ) do
      persist_response(config, current, creation, observed)
    else
      false ->
        failed_observation(config, record, %Error{
          category: :identity_conflict,
          operation: :inspect
        })

      error ->
        error
    end
  end

  defp complete_response(config, record, :ok), do: confirm(config, record)
  defp complete_response(config, record, {:error, error}), do: uncertain(config, record, error)

  defp complete_response(config, record, _invalid),
    do: uncertain(config, record, %Error{category: :protocol, operation: :machine})

  # Port v2 start already verifies the enrolled process and guest readiness.
  # Commit its matching observation under the receiving operation's store guard.
  defp persist_response(
         config,
         %{operation: :start, backend_assignment: %Assignment{version: 2}} = current,
         _creation,
         %Machine{state: :running, backend_identity: %NativeIdentity{pid_identity: [_, _]}} =
           observed
       ),
       do: write(config, current, completed_changes(config, observed))

  defp persist_response(config, current, creation, observed) do
    with {:ok, saved} <-
           write(config, current, created_machine: creation, observed_machine: observed),
         do: confirm(config, saved)
  end

  # Only the process receiving the mutation response may complete a start/stop.
  # Recovery cannot distinguish an observed state from a delayed old request.
  defp confirm(config, record) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         {:ok, worker} <- worker(config, current) do
      case inspect(config, current, worker) do
        {:ok, observed} ->
          confirm_present(config, current, observed)

        {:error, %Error{category: :not_found}} when current.operation == :delete ->
          deleted(config, current)

        {:error, error} ->
          uncertain(config, current, error)
      end
    end
  end

  defp confirm_present(config, record, observed) do
    expected = %{start: :running, stop: :stopped, create: observed.state}[record.operation]

    if record.created_machine != nil and
         SmolBox.DiskExpansion.matches?(record, observed) and
         observed.state == expected do
      fresh_write(config, record, completed_changes(config, observed))
    else
      uncertain(config, record, %Error{category: :unknown, operation: :inspect})
    end
  end

  defp completed_changes(config, observed) do
    [
      state: observed.state,
      observed_machine: observed,
      operation: nil,
      phase: nil,
      operation_deadline_ms: nil,
      last_error: nil,
      next_due_at_ms: config.clock.now() + 60_000
    ]
  end

  # A native name/intent cannot replace a missing creation receipt. Automatic
  # observation must stay uncertain; only explicit quiesced creation inspection
  # may prove absence. Defer normally so versioned resolution can acquire it.
  defp observe(
         config,
         %{backend_assignment: %SmolBox.Backend.Assignment{}, created_machine: nil} = record
       ) do
    fresh_write(config, record,
      state: :unknown,
      phase: if(record.operation, do: :uncertain),
      last_error: %Error{category: :unknown, operation: :inspect, evidence: :not_dispatched},
      next_due_at_ms: config.clock.now() + 60_000
    )
  end

  defp observe(config, record) do
    record = %{record | operation_deadline_ms: nil}

    with {:ok, worker} <- worker(config, record) do
      case inspect(config, record, worker) do
        {:ok, observed} -> observe_present(config, record, observed)
        {:error, %Error{category: :not_found}} -> observe_absent(config, record)
        {:error, error} -> failed_observation(config, record, error)
      end
    end
  end

  defp inspect(config, record, worker),
    do:
      io(config, record, fn ->
        Backend.inspect_machine(Target.connection(worker, record), record.machine_name)
      end)

  defp observe_present(config, record, observed) do
    cond do
      record.created_machine == nil ->
        uncertain(config, record, %Error{category: :unknown, operation: :create})

      not SmolBox.DiskExpansion.matches?(record, observed) ->
        failed_observation(config, record, %Error{
          category: :identity_conflict,
          operation: :inspect
        })

      record.phase != nil or record.state in [:unknown, :missing, :conflict] ->
        fresh_write(config, record,
          state: :unknown,
          observed_machine: observed,
          phase: if(record.operation, do: :uncertain),
          next_due_at_ms: config.clock.now() + 60_000
        )

      record.state != observed.state ->
        uncertain(config, record, %Error{category: :unknown, operation: :inspect})

      true ->
        fresh_write(config, record,
          state: observed.state,
          observed_machine: observed,
          next_due_at_ms: config.clock.now() + 60_000
        )
    end
  end

  defp observe_absent(config, %{operation: :delete, created_machine: creation} = record)
       when not is_nil(creation), do: deleted(config, record)

  defp observe_absent(config, record),
    do: fresh_write(config, record, state: :missing, next_due_at_ms: config.clock.now() + 60_000)

  defp deleted(config, record),
    do:
      fresh_write(config, record,
        state: :deleted,
        operation: nil,
        phase: nil,
        absence_at_ms: config.clock.now(),
        operation_deadline_ms: nil
      )

  defp uncertain(config, record, error),
    do:
      fresh_write(config, record,
        state: :unknown,
        phase: if(record.operation, do: :uncertain),
        last_error: %{error | evidence: :unknown},
        next_due_at_ms: config.clock.now() + 60_000
      )

  defp failed_observation(config, record, %Error{category: :identity_conflict} = error),
    do:
      fresh_write(config, record,
        state: :conflict,
        last_error: error,
        next_due_at_ms: config.clock.now() + 60_000
      )

  defp failed_observation(config, record, %Error{category: :not_found}),
    do: observe_absent(config, record)

  defp failed_observation(config, record, error),
    do:
      fresh_write(config, record, last_error: error, next_due_at_ms: config.clock.now() + 60_000)

  defp fresh_write(config, record, changes) do
    with {:ok, current} <- claim(config, ManagedMachine.key(record)),
         # I/O may have overlapped a new lifecycle request or command. Renewed
         # claims do not authorize applying the old observation to newer work.
         fields = [:state, :operation, :phase, :last_request, :active_execution],
         true <- Map.take(current, fields) == Map.take(record, fields) do
      write(config, current, changes)
    else
      false -> Session.error(:stale_version, :machine)
      error -> error
    end
  end

  defdelegate worker(config, record), to: SmolBox.Runtime.MachineSession
  defdelegate io(config, record, function), to: SmolBox.Runtime.MachineSession
end
