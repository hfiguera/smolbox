defmodule SmolBox.Store.ExpansionOps do
  @moduledoc false
  alias SmolBox.{DiskExpansion, Error, ManagedMachine, Validation}

  def accept(m, id, version, targets, capacity, usage, now) do
    with true <-
           Validation.identifier?(id) and Validation.integer?(version, 1, 9_007_199_254_740_991),
         {:ok, _} <- DiskExpansion.targets(Map.to_list(targets)) do
      case m.disk_expansions[id] do
        %DiskExpansion{} = r ->
          duplicate(m, r, version, targets)

        nil ->
          insert(m, id, version, targets, capacity, usage, now)
      end
    else
      _ -> error(:validation)
    end
  end

  defp duplicate(m, r, version, targets) do
    if r.request == targets and r.requested_version == version,
      do: {:ok, m},
      else: error(:identity_conflict)
  end

  defp available?(m), do: ManagedMachine.idle?(m) and m.state in [:created, :stopped]

  defp growing?(sizes, current),
    do: sizes != current and Enum.all?(current, fn {k, v} -> sizes[k] >= v end)

  defp insert(m, id, version, targets, capacity, usage, now) do
    current = Map.take(DiskExpansion.profile(m), [:storage_gb, :overlay_gb])
    sizes = Map.merge(current, targets)
    delta = sizes.storage_gb + sizes.overlay_gb - DiskExpansion.reserved_disk(m)

    cond do
      version != m.version ->
        error(:stale_version)

      not DiskExpansion.supported?(m) ->
        error(:unsupported_capability)

      not available?(m) ->
        error(:admission_exhausted)

      not growing?(sizes, current) ->
        error(:validation)

      map_size(m.disk_expansions) >= 32 or not fits?(delta, capacity, usage) ->
        error(:admission_exhausted)

      true ->
        r =
          struct!(
            DiskExpansion,
            Map.merge(sizes, %{
              id: id,
              requested_version: version,
              accepted_at_ms: now,
              request: targets
            })
          )

        ManagedMachine.update(
          m,
          %{
            disk_expansions: Map.put(m.disk_expansions, id, r),
            disk_sizes: current,
            active_expansion: id,
            operation: :expand_disks,
            phase: :pending,
            operation_deadline_ms: nil,
            next_due_at_ms: now,
            reservation: %{m.reservation | disk_gb: sizes.storage_gb + sizes.overlay_gb}
          },
          now
        )
    end
  end

  defp fits?(delta, capacity, usage),
    do:
      is_integer(capacity[:disk_gb]) and is_integer(usage[:disk_gb]) and delta >= 0 and
        usage.disk_gb + delta <= capacity.disk_gb

  def advance(m, id, expected, outcome, now) do
    with %DiskExpansion{state: ^expected} = r <- m.disk_expansions[id],
         true <- m.active_expansion == id do
      apply_outcome(m, r, outcome, now)
    else
      _ -> error(:stale_version)
    end
  end

  defp apply_outcome(m, %{state: :pending} = r, :dispatch, now),
    do:
      save(
        m,
        r,
        :dispatching,
        %{phase: :dispatching, operation_deadline_ms: now + m.spec.profile.preparation_ms},
        now
      )

  defp apply_outcome(m, r, {:unknown, %Error{} = error}, now) do
    save(
      m,
      r,
      :unknown,
      %{
        state: :unknown,
        phase: :uncertain,
        last_error: %{error | evidence: :unknown},
        next_due_at_ms: now + 60_000
      },
      now
    )
  end

  defp apply_outcome(m, %{state: :dispatching} = r, {:complete, observed}, now),
    do: complete(m, r, observed, :completed, now)

  defp apply_outcome(m, %{state: :unknown} = r, {:resolve, :absent}, now) do
    save(
      m,
      r,
      :deleted,
      %{
        state: :deleted,
        active_expansion: nil,
        operation: nil,
        phase: nil,
        reservation: nil,
        reserved_ports: [],
        absence_at_ms: m.absence_at_ms || now,
        resolved_at_ms: now,
        operation_deadline_ms: nil,
        last_error: nil
      },
      now
    )
  end

  defp apply_outcome(m, %{state: :unknown} = r, {:resolve, observed}, now),
    do: complete(m, r, observed, :resolved, now)

  defp apply_outcome(_, _, _, _), do: error(:validation)

  defp complete(m, r, observed, state, now) do
    if observed.state in [:created, :stopped] and DiskExpansion.target_matches?(m, r, observed) do
      save(
        m,
        r,
        state,
        %{
          state: observed.state,
          observed_machine: observed,
          disk_sizes: Map.take(r, [:storage_gb, :overlay_gb]),
          active_expansion: nil,
          operation: nil,
          phase: nil,
          operation_deadline_ms: nil,
          last_error: nil,
          next_due_at_ms: now + 60_000,
          resolved_at_ms: if(state == :resolved, do: now, else: m.resolved_at_ms)
        },
        now
      )
    else
      error(:identity_conflict)
    end
  end

  defp save(m, r, state, changes, now),
    do:
      ManagedMachine.update(
        m,
        Map.put(changes, :disk_expansions, Map.put(m.disk_expansions, r.id, %{r | state: state})),
        now
      )

  defp error(category), do: {:error, %Error{category: category, operation: :expand_disks}}
end
