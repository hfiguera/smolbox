defmodule SmolBox.Store.BranchOps do
  @moduledoc "Atomic source/child transactions; adapters serialize both identities and worker capacity."
  alias SmolBox.{Branch, BranchSpec, Error, Machine, ManagedMachine, Validation}
  alias SmolBox.Store.RecordOps

  def accept(parent, spec, fingerprint, name, capacity, usage, now) do
    with :ok <- BranchSpec.validate(spec),
         true <- Validation.digest?(fingerprint),
         true <- parent.state == :running and ManagedMachine.idle?(parent),
         true <- parent.branch == nil and parent.spec.checkpointable and parent.id != spec.id,
         true <-
           map_size(parent.branch_children) < 256 and
             not Map.has_key?(parent.branch_children, spec.id),
         true <- SmolBox.MachineSpec.valid_name?(name),
         true <- capacity?(parent, spec, capacity, usage),
         {:ok, child} <-
           ManagedMachine.new(
             %{parent.spec | id: spec.id, checkpointable: false},
             fingerprint,
             now
           ),
         b = %Branch{
           source: ManagedMachine.key(parent),
           source_machine: parent.created_machine,
           spec: spec,
           accepted_at_ms: now,
           deadline_ms: now + spec.timeout_ms
         },
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: b,
               worker_id: parent.worker_id,
               worker_generation: parent.worker_generation,
               machine_name: name,
               reservation: RecordOps.resources(child),
               state: :creating,
               operation: :branch_child,
               phase: :pending,
               operation_deadline_ms: b.deadline_ms
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               branch_children: Map.put(parent.branch_children, spec.id, false),
               active_branch: spec.id,
               operation: :branch,
               phase: :pending,
               operation_deadline_ms: b.deadline_ms,
               next_due_at_ms: now
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error(:admission_exhausted))
  end

  defp capacity?(parent, spec, capacity, usage) do
    p = parent.spec.profile
    extra = spec.policy.resources
    needed = Map.merge(RecordOps.resources(parent), extra, fn _, a, b -> a + b end)

    extra.memory_mb >= p.memory_mb + p.host_overhead_mb and
      extra.disk_gb >= 2 * (p.storage_gb + p.overlay_gb) + div(p.memory_mb + 1023, 1024) and
      is_map(capacity) and Enum.sort(Map.keys(capacity)) == Enum.sort(Map.keys(needed)) and
      Enum.all?(needed, fn {k, v} ->
        is_integer(capacity[k]) and is_integer(usage[k]) and usage[k] + v <= capacity[k]
      end)
  end

  def advance(parent, child, expected, change, now) do
    with true <- related?(parent, child) and parent.active_branch == child.id,
         true <- child.branch.state == expected,
         {:ok, parent, child} <- create_step(parent, child, change, now),
         do: {:ok, parent, child},
         else: (_ -> error(:stale_version))
  end

  defp create_step(p, c, :dispatching, now) when c.branch.state == :accepted,
    do: save(p, c, :dispatching, %{phase: :dispatching}, now)

  defp create_step(p, c, {:observed, %Machine{} = observed}, now)
       when c.branch.state == :dispatching do
    if observed.state == :running,
      do: save(p, c, :observed, %{created_machine: observed, observed_machine: observed}, now),
      else: error(:identity_conflict)
  end

  defp create_step(p, c, {:complete, source}, now) when c.branch.state == :observed do
    if owned_source?(p, c, source) and source.state == :running,
      do: finish(p, c, if(c.branch.spec.hold, do: :held, else: :ready), source, now),
      else: error(:identity_conflict)
  end

  defp create_step(p, c, :unknown, now) when c.branch.state in [:dispatching, :observed] do
    with {:ok, p} <-
           ManagedMachine.update(
             p,
             %{state: :unknown, phase: :uncertain, next_due_at_ms: now + 60_000},
             now
           ),
         do:
           save(
             p,
             c,
             :unknown,
             %{state: :unknown, phase: :uncertain, last_error: uncertain()},
             now
           )
  end

  defp create_step(p, c, action, now)
       when c.branch.state == :accepted and action in [:failed, :cancelled] do
    with {:ok, c} <- deleted(c, action, now),
         {:ok, p} <- unlock(p, p.observed_machine || p.created_machine, now),
         {:ok, p} <-
           ManagedMachine.update(
             p,
             %{branch_children: Map.put(p.branch_children, c.id, true)},
             now
           ),
         do: {:ok, p, c}
  end

  defp create_step(_, _, _, _), do: error(:stale_version)

  def resolve(p, c, source, child_observation, now) do
    with true <- related?(p, c),
         true <- c.branch.state in [:unknown, :observed, :release_dispatching],
         true <-
           p.active_branch in [nil, c.id] and (p.active_branch == c.id or ManagedMachine.idle?(p)),
         true <-
           (source == :absent and child_observation == :absent) or owned_source?(p, c, source),
         {:ok, c} <- resolve_child(c, child_observation, now),
         {:ok, p} <- unlock(p, source, now),
         do: {:ok, p, c},
         else: (_ -> error(:identity_conflict))
  end

  defp resolve_child(c, :absent, now), do: deleted(c, :resolved, now)

  defp resolve_child(%{created_machine: %Machine{} = created} = c, observed, now) do
    if c.branch.release_version == nil and observed.state == :running and
         Machine.same_incarnation?(created, observed),
       do:
         update(
           c,
           if(c.branch.spec.hold, do: :held, else: :ready),
           %{
             state: :running,
             observed_machine: observed,
             operation: nil,
             phase: nil,
             last_error: nil,
             operation_deadline_ms: nil,
             next_due_at_ms: now + 60_000
           },
           now
         ),
       else: error(:identity_conflict)
  end

  defp resolve_child(_, _, _), do: error(:identity_conflict)

  def release(c, version, now) do
    cond do
      c.branch == nil ->
        error(:validation)

      c.branch.release_version == version ->
        {:ok, c}

      c.version != version ->
        error(:stale_version)

      c.branch.state != :held or c.state != :running or not ManagedMachine.idle?(c) ->
        error(:admission_exhausted)

      true ->
        b = %{c.branch | release_version: version, deadline_ms: now + c.branch.spec.timeout_ms}

        update(
          %{c | branch: b},
          :release_pending,
          %{
            operation: :branch_release,
            phase: :pending,
            operation_deadline_ms: b.deadline_ms,
            next_due_at_ms: now
          },
          now
        )
    end
  end

  def release_advance(c, expected, action, now) do
    if c.branch != nil and c.branch.state == expected,
      do: release_step(c, action, now),
      else: error(:stale_version)
  end

  defp release_step(c, :dispatching, now) when c.branch.state == :release_pending,
    do: update(c, :release_dispatching, %{phase: :dispatching}, now)

  defp release_step(c, {:complete, observed}, now) when c.branch.state == :release_dispatching do
    if observed.state == :running and Machine.same_incarnation?(c.created_machine, observed),
      do:
        update(
          c,
          :released,
          %{
            state: :running,
            observed_machine: observed,
            operation: nil,
            phase: nil,
            operation_deadline_ms: nil,
            last_error: nil,
            next_due_at_ms: now + 60_000
          },
          now
        ),
      else: error(:identity_conflict)
  end

  defp release_step(c, :unknown, now)
       when c.branch.state in [:release_pending, :release_dispatching],
       do:
         update(
           c,
           :unknown,
           %{
             state: :unknown,
             phase: :uncertain,
             last_error: uncertain(),
             next_due_at_ms: now + 60_000
           },
           now
         )

  defp release_step(_, _, _), do: error(:stale_version)

  def release_storage(p, c, now) do
    with true <- related?(p, c) and p.state == :deleted and c.state == :deleted,
         true <- c.branch.state in [:retired, :closed],
         do: update(c, :closed, %{}, now),
         else: (_ -> error(:identity_conflict))
  end

  def retire(p, %{branch: %{state: :closed}} = c, _now) do
    if related?(p, c), do: {:ok, p, c}, else: error(:identity_conflict)
  end

  def retire(p, c, now) do
    with true <- related?(p, c) and c.state == :deleted and p.active_branch != c.id,
         true <- c.branch.state in [:ready, :held, :released, :resolved, :retired],
         {:ok, c} <-
           update(
             %{c | branch: %{c.branch | retired_at_ms: c.branch.retired_at_ms || now}},
             :retired,
             %{},
             now
           ),
         {:ok, p} <-
           ManagedMachine.update(
             p,
             %{branch_children: Map.put(p.branch_children, c.id, true)},
             now
           ),
         do: {:ok, p, c},
         else: (_ -> error(:identity_conflict))
  end

  defp related?(p, c),
    do:
      c.branch != nil and c.branch.source == ManagedMachine.key(p) and
        p.worker_id == c.worker_id and Map.has_key?(p.branch_children, c.id)

  defp owned_source?(_, _, :absent), do: false

  defp owned_source?(p, c, source),
    do:
      source.state in [:running, :stopped] and
        Machine.same_incarnation?(p.created_machine, source) and
        Machine.same_incarnation?(c.branch.source_machine, source)

  defp save(p, c, state, changes, now) do
    with {:ok, c} <- update(c, state, changes, now), do: {:ok, p, c}
  end

  defp update(c, state, changes, now),
    do: ManagedMachine.update(c, Map.put(changes, :branch, %{c.branch | state: state}), now)

  defp deleted(c, state, now),
    do:
      update(
        c,
        state,
        %{
          state: :deleted,
          reservation: nil,
          operation: nil,
          phase: nil,
          last_error: nil,
          absence_at_ms: c.absence_at_ms || now,
          operation_deadline_ms: nil
        },
        now
      )

  defp unlock(p, :absent, now),
    do:
      ManagedMachine.update(
        p,
        %{
          active_branch: nil,
          operation: nil,
          phase: nil,
          operation_deadline_ms: nil,
          state: :missing,
          next_due_at_ms: now + 60_000
        },
        now
      )

  defp unlock(p, source, now),
    do:
      ManagedMachine.update(
        p,
        %{
          active_branch: nil,
          operation: nil,
          phase: nil,
          operation_deadline_ms: nil,
          state: source.state,
          observed_machine: source,
          last_error: nil,
          next_due_at_ms: now + 60_000
        },
        now
      )

  defp finish(p, c, state, source, now) do
    with {:ok, p} <- unlock(p, source, now),
         {:ok, c} <-
           update(
             c,
             state,
             %{
               state: :running,
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, p, c}
  end

  defp uncertain, do: %Error{category: :unknown, operation: :branch, evidence: :unknown}
  defp error(category), do: {:error, %Error{category: category, operation: :branch}}
end
