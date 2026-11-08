defmodule SmolBox.Runtime.NativeRecovery do
  @moduledoc false
  alias SmolBox.{Backend, DiskExpansion, Error, Execution, Machine, ManagedMachine}
  alias SmolBox.Backend.EmbeddedContext
  alias SmolBox.Embedded.{Call, Health, NativeCapture}

  alias SmolBox.Runtime.{
    MachineSession,
    NativeAuthority,
    NativeVolumeRecovery,
    Session,
    Target,
    WorkerHealth
  }

  alias SmolBox.Store.BackendAssignments

  def observe(config, target, previous, coordinator) do
    case Session.safe(fn -> step(config, target, previous, coordinator) end) do
      {:ok, observation} ->
        observation

      {:error, %Error{} = error} ->
        report(config, :unavailable, nil) |> Map.put(:recovery_error, error)

      _unavailable ->
        report(config, :unavailable, nil)
    end
  end

  defp step(config, target, previous, coordinator) do
    target = Target.pin(target)
    context = target.connection.context

    with {:ok, health} <- Call.health(context, %{target.connection.budget | timeout_ms: 1000}),
         true <- health.status in [:ready, :reconciling] do
      channel = {context.server, context.epoch}

      recovery =
        if previous && previous[:channel] == channel,
          do: previous,
          else: %{channel: channel, cursor: nil, phase: :scanning}

      if recovery.phase == :ready and health.status == :ready and
           NativeAuthority.available?(coordinator, target.id) do
        {:ok, WorkerHealth.observe(target, config.clock) |> Map.put(:recovery, recovery)}
      else
        coordinated_scan(config, target, recovery, coordinator)
      end
    else
      _ -> Session.error(:unknown, :reconcile)
    end
  end

  defp coordinated_scan(config, target, recovery, coordinator),
    do:
      NativeAuthority.run(coordinator, target.id, fn ->
        scan(config, target, recovery, coordinator)
      end)

  defp scan(config, target, recovery, coordinator) do
    {owner, epoch} = recovery.channel
    bridge = EmbeddedContext.bridge(target.connection.context)

    with :ok <- freeze(coordinator, target.id),
         :ok <- bridge.quiesce(owner, epoch),
         {:ok, _lease} <- lease(config, target),
         {:ok, records, cursor} <-
           Session.store(config, :backend_assignments, [target.id, recovery.cursor, 1]),
         true <-
           BackendAssignments.valid_single_result?(target.id, recovery.cursor, records, cursor),
         :ok <- classify_page(config, target, records) do
      finish_page(config, target, %{recovery | cursor: cursor}, coordinator)
    else
      {:error, %Error{category: :admission_exhausted}} ->
        {:ok, report(config, :unavailable, recovery)}

      {:error, %Error{}} = error ->
        error

      _failed ->
        Session.error(:store, :reconcile)
    end
  end

  defp finish_page(config, target, %{cursor: nil} = recovery, coordinator) do
    {owner, epoch} = recovery.channel
    bridge = EmbeddedContext.bridge(target.connection.context)

    with {:ok, _lease} <- lease(config, target),
         :ok <- bridge.activate(owner, target.domain_binding, epoch),
         :ok <- GenServer.call(coordinator, {:native_ready, target.id}),
         {:ok, health} <-
           Call.health(target.connection.context, %{target.connection.budget | timeout_ms: 1000}) do
      {:ok,
       report(config, :ready, %{recovery | phase: :ready})
       |> Map.put(:health, Health.describe(target.native_config, health))}
    end
  end

  defp finish_page(config, _target, recovery, _coordinator),
    do: {:ok, report(config, :unavailable, recovery)}

  defp freeze(coordinator, id), do: GenServer.call(coordinator, {:native_quiesce, id})

  defp lease(config, target),
    do:
      Session.store(config, :claim_worker, [
        target.id,
        config.owner,
        config.clock.now(),
        config.lease_ms
      ])

  defp classify_page(config, target, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case classify(config, target, record) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp classify(config, target, %SmolBox.Volume{} = volume),
    do: NativeVolumeRecovery.classify(config, target, volume)

  defp classify(config, target, record) do
    with true <-
           record.worker_id == target.id and record.backend_assignment != nil and
             Map.from_struct(record.backend_assignment.binding) == target.domain_binding,
         reference = Target.connection(target, record),
         {:ok, observed} <- observation(reference, record),
         true <- observation_valid?(record, observed) do
      persist(config, record, observed)
    else
      _invalid -> Session.error(:identity_conflict, :reconcile)
    end
  end

  defp observation(_reference, %{created_machine: nil}), do: {:ok, :unverified}

  defp observation(reference, record) do
    case Backend.inspect_machine(
           Backend.bounded(reference,
             timeout_ms: 1000,
             max_response_bytes: 16_384
           ),
           record.machine_name
         ) do
      {:error, %Error{category: :not_found}} -> {:ok, :missing}
      result -> result
    end
  end

  @doc false
  def observation_valid?(record, :unverified),
    do:
      record.reservation != nil or Map.get(record, :managed_machine) != nil or
        record.absence_at_ms != nil

  def observation_valid?(_record, :missing), do: true

  def observation_valid?(%ManagedMachine{} = record, %Machine{} = observed) do
    record.reservation != nil and
      (NativeCapture.observation_valid?(record, observed) or
         case record.disk_expansions[record.active_expansion] do
           %DiskExpansion{state: state} = expansion when state in [:dispatching, :unknown] ->
             DiskExpansion.target_matches?(record, expansion, observed)

           _ ->
             false
         end)
  end

  def observation_valid?(record, %Machine{} = observed),
    do:
      (record.reservation != nil or Map.get(record, :managed_machine) != nil) and
        Machine.same_incarnation?(record.created_machine, observed)

  # Historical retained commands no longer own their machine's slot and the
  # stores correctly reject new claims on them. Receipt validation/observation
  # above still applies; preserve completed cleanup without reclaiming the slot.
  defp persist(_config, %Execution{cleanup: :complete, reservation: nil}, _observed), do: :ok

  defp persist(config, %Execution{} = record, observed) do
    with {:ok, current} <-
           Session.store(config, :claim, [
             Execution.key(record),
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         true <- same_work?(record, current),
         {:ok, saved} <-
           Session.write(
             Session.new(config, current),
             current,
             cleanup_changes(
               current,
               observed,
               config.clock.now(),
               execution_changes(current, observed)
             )
           ),
         :ok <- finish_execution(config, saved) do
      :ok
    else
      {:error, %Error{}} = error -> error
      _ -> Session.error(:stale_version, :reconcile)
    end
  end

  defp persist(config, %ManagedMachine{} = record, observed) do
    with {:ok, current} <- MachineSession.claim(config, ManagedMachine.key(record)),
         true <- same_work?(record, current),
         {:ok, _saved} <- persist_machine(config, current, observed),
         do: :ok,
         else: (_ -> Session.error(:stale_version, :reconcile))
  end

  defp persist_machine(config, %{active_expansion: id} = record, _observed)
       when not is_nil(id) do
    # Startup observation never resolves growth or imports the proof into its
    # history. Keep the full reservation and make interrupted intent explicitly
    # unknown, including when the journal already contains completed evidence.
    expansion = record.disk_expansions[id]

    MachineSession.store(config, :expansion_advance, [
      ManagedMachine.key(record),
      Session.guard(record),
      id,
      expansion.state,
      {:unknown, unknown()},
      config.clock.now()
    ])
  end

  defp persist_machine(config, %{active_capture: id} = record, observed) when not is_nil(id) do
    case record.captures[id].state do
      :dispatching ->
        MachineSession.store(config, :capture_advance, [
          ManagedMachine.key(record),
          Session.guard(record),
          id,
          :dispatching,
          [state: :unknown, error: %{unknown() | operation: :checkpoint}],
          config.clock.now()
        ])

      :unknown ->
        MachineSession.write(config, record, next_due_at_ms: record.next_due_at_ms)

      _ ->
        MachineSession.write(config, record, machine_changes(record, observed))
    end
  end

  defp persist_machine(config, record, observed),
    do: MachineSession.write(config, record, machine_changes(record, observed))

  defp execution_changes(%{state: :collecting} = record, _observed) do
    if length(record.artifacts) == length(record.spec.outputs),
      do: [state: :completed, collection: :complete],
      else: [
        state: :collection_failed,
        collection: if(record.artifacts == [], do: :failed, else: :partial),
        last_error: unknown()
      ]
  end

  defp execution_changes(%{state: state} = record, observed)
       when state in [:accepted, :preparing, :ready, :dispatching, :running, :cancelling] do
    [
      state: :unknown,
      evidence: if(observed == :missing, do: :termination_confirmed, else: :unknown),
      last_error: unknown(),
      next_due_at_ms: record.updated_at_ms
    ]
  end

  defp execution_changes(record, _observed), do: [next_due_at_ms: record.next_due_at_ms]

  defp cleanup_changes(
         %{managed_machine: nil, created_machine: machine} = record,
         :missing,
         now,
         changes
       )
       when not is_nil(machine) do
    Keyword.merge(changes,
      cleanup: :complete,
      absence_at_ms: record.absence_at_ms || now,
      evidence:
        if(Keyword.get(changes, :state, record.state) == :unknown,
          do: :termination_confirmed,
          else: record.evidence
        )
    )
  end

  defp cleanup_changes(_record, _observed, _now, changes), do: changes

  defp finish_execution(
         config,
         %{managed_machine: nil, reservation: reservation, cleanup: :complete} = record
       )
       when not is_nil(reservation) do
    case Session.store(config, :release, [
           Execution.key(record),
           Session.guard(record),
           config.clock.now()
         ]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp finish_execution(_config, %{managed_machine: nil}), do: :ok
  defp finish_execution(_config, %{cleanup: :complete}), do: :ok

  defp finish_execution(config, record) do
    case MachineSession.store(config, :finish, [
           Execution.key(record),
           Session.guard(record),
           config.clock.now()
         ]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp machine_changes(%{state: :deleted} = record, observation)
       when observation in [:missing, :unverified],
       do: [next_due_at_ms: record.next_due_at_ms]

  defp machine_changes(record, observed) do
    state = machine_state(record, observed)

    [
      state: state,
      observed_machine:
        if(is_struct(observed, Machine), do: observed, else: record.observed_machine),
      phase: if(record.operation, do: :uncertain),
      operation_deadline_ms: nil,
      last_error: if(state in [:unknown, :missing], do: unknown(), else: nil),
      next_due_at_ms: record.updated_at_ms
    ]
  end

  defp machine_state(_record, :missing), do: :missing
  defp machine_state(_record, :unverified), do: :unknown
  defp machine_state(%{operation: operation}, _observed) when not is_nil(operation), do: :unknown

  defp machine_state(%{active_execution: execution}, _observed) when not is_nil(execution),
    do: :unknown

  defp machine_state(%{state: state}, _observed) when state in [:unknown, :missing, :conflict],
    do: :unknown

  defp machine_state(_record, %{state: :stopped}), do: :stopped
  defp machine_state(_record, _observed), do: :unknown

  defp same_work?(before, after_claim),
    do:
      Map.drop(Map.from_struct(before), [
        :claim_owner,
        :claim_until_ms,
        :generation,
        :worker_generation,
        :version,
        :updated_at_ms
      ]) ==
        Map.drop(Map.from_struct(after_claim), [
          :claim_owner,
          :claim_until_ms,
          :generation,
          :worker_generation,
          :version,
          :updated_at_ms
        ])

  defp unknown, do: %Error{category: :unknown, operation: :reconcile, evidence: :unknown}

  defp report(config, status, recovery),
    do: %{
      status: status,
      health: nil,
      recovery: recovery,
      checked_at_ms: config.clock.now(),
      checked_monotonic: config.clock.monotonic()
    }
end
