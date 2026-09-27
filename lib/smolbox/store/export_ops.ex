defmodule SmolBox.Store.ExportOps do
  @moduledoc """
  Pure export transactions. Adapters lock all machine histories, resource totals
  and the source together. Tag claims survive every outcome and machine deletion.
  """
  alias SmolBox.{Error, Export, ExportSpec, ManagedMachine, Validation}

  def accept(machine, spec, fingerprint, capacity, usage, machines, now) do
    with :ok <- ExportSpec.validate(spec),
         true <- Validation.digest?(fingerprint) do
      case machine.exports[spec.id] do
        %Export{fingerprint: ^fingerprint} -> {:ok, machine}
        %Export{} -> error(:identity_conflict)
        nil -> insert(machine, spec, fingerprint, capacity, usage, machines, now)
      end
    else
      _invalid -> error(:validation)
    end
  end

  defp insert(machine, spec, fingerprint, capacity, usage, machines, now) do
    with true <- machine.branch == nil and SmolBox.Branch.children_retired?(machine),
         true <- machine.state == :stopped and ManagedMachine.idle?(machine),
         true <- machine.spec.artifact["kind"] != "checkpoint",
         true <- map_size(machine.exports) < 256,
         true <- resource_floor?(spec.destination.resources, machine.spec.profile),
         true <- fits?(spec.destination.resources, capacity, usage),
         true <- vacant?(spec, machine.spec.artifact["architecture"], machines),
         {:ok, export} <- Export.new(ManagedMachine.key(machine), spec, fingerprint, now) do
      ManagedMachine.update(
        machine,
        %{
          exports: Map.put(machine.exports, spec.id, export),
          active_export: spec.id,
          operation: :export,
          phase: :pending,
          operation_deadline_ms: export.deadline_ms,
          next_due_at_ms: now
        },
        now
      )
    else
      false -> error(:admission_exhausted)
      error -> error
    end
  end

  # A store write is a compare-and-swap of the export state as well as the outer
  # machine guard. A late response cannot complete cancelled/resolved/new work.
  def advance(machine, id, expected, changes, now) do
    with %Export{} = record <- machine.exports[id],
         true <- machine.active_export == id and record.state == expected,
         true <- Validation.keys?(changes, [:state, :receipt, :result, :error, :resolved_at_ms]),
         true <- allowed?(record.state, changes[:state]),
         true <- safe_release?(record.state, changes),
         true <-
           record.receipt == nil or
             Keyword.get(changes, :receipt, record.receipt) == record.receipt,
         next =
           struct!(
             record,
             changes ++
               [version: record.version + 1, updated_at_ms: max(now, record.updated_at_ms)]
           ),
         :ok <- Export.validate(next) do
      save(machine, next, now)
    else
      _invalid -> error(:stale_version)
    end
  end

  def cancel(machine, id, now) do
    case machine.exports[id] do
      %Export{state: :accepted} ->
        advance(machine, id, :accepted, [state: :cancelled], now)

      %Export{state: state} when state in [:dispatching, :verifying] ->
        advance(
          machine,
          id,
          state,
          [
            state: :unknown,
            error: %Error{category: :unknown, operation: :export, evidence: :unknown}
          ],
          now
        )

      %Export{} ->
        {:ok, machine}

      nil ->
        error(:not_found)
    end
  end

  def resolve(machine, id, :absent, now) do
    with %Export{state: state} <- machine.exports[id],
         true <- state in [:unknown, :published],
         {:ok, saved} <-
           advance(
             machine,
             id,
             state,
             [
               state: if(state == :published, do: :completed, else: :resolved_unknown),
               resolved_at_ms: now
             ],
             now
           ) do
      ManagedMachine.update(
        saved,
        %{
          state: :deleted,
          absence_at_ms: saved.absence_at_ms || now,
          reservation: nil,
          reserved_ports: [],
          last_error: nil
        },
        now
      )
    else
      _invalid -> error(:identity_conflict)
    end
  end

  def resolve(machine, id, observed, now) do
    with %Export{state: state} <- machine.exports[id],
         true <- state in [:unknown, :published],
         true <- observed.state == :stopped,
         true <- SmolBox.Machine.same_incarnation?(machine.created_machine, observed),
         {:ok, saved} <-
           advance(
             machine,
             id,
             state,
             [
               state: if(state == :published, do: :completed, else: :resolved_unknown),
               resolved_at_ms: now
             ],
             now
           ) do
      ManagedMachine.update(
        saved,
        %{state: :stopped, observed_machine: observed, last_error: nil},
        now
      )
    else
      _invalid -> error(:identity_conflict)
    end
  end

  defp save(machine, export, now) do
    terminal = Export.terminal?(export)
    phase = if terminal, do: nil, else: phase(export.state)

    ManagedMachine.update(
      machine,
      %{
        exports: Map.put(machine.exports, export.spec.id, export),
        active_export: if(terminal, do: nil, else: export.spec.id),
        operation: if(terminal, do: nil, else: :export),
        phase: phase,
        state: if(export.state == :unknown, do: :unknown, else: machine.state),
        operation_deadline_ms: if(terminal, do: nil, else: export.deadline_ms),
        next_due_at_ms:
          if(export.state in [:unknown, :published] or terminal, do: now + 60_000, else: now)
      },
      now
    )
  end

  defp phase(:accepted), do: :pending
  defp phase(:published), do: :uncertain
  defp phase(:unknown), do: :uncertain
  defp phase(_state), do: :dispatching
  defp allowed?(:accepted, next), do: next in [:dispatching, :failed, :cancelled]
  defp allowed?(:dispatching, next), do: next in [:verifying, :unknown, :failed]
  defp allowed?(:verifying, next), do: next in [:published, :unknown]
  defp allowed?(:published, :completed), do: true
  defp allowed?(:unknown, :resolved_unknown), do: true
  defp allowed?(_previous, _next), do: false

  defp safe_release?(:dispatching, changes) do
    changes[:state] != :failed or
      match?(%Error{evidence: :not_dispatched}, changes[:error])
  end

  defp safe_release?(_state, _changes), do: true

  # The helper's minimum sparse disk plus source-sized staging. Packed layers
  # and operator overrides can require more; destination approval attests to
  # that additional headroom and host filesystem controls.
  defp resource_floor?(resources, profile),
    do:
      resources.disk_gb >=
        max(64, profile.storage_gb * 3) + profile.storage_gb + profile.overlay_gb

  defp fits?(needed, capacity, usage) do
    is_map(capacity) and Map.keys(capacity) == Map.keys(needed) and
      Enum.all?(needed, fn {key, value} ->
        Validation.integer?(capacity[key], 1, 1_048_576) and
          is_integer(usage[key]) and usage[key] + value <= capacity[key]
      end)
  end

  defp vacant?(spec, architecture, machines) do
    target = spec.destination
    tags = ExportSpec.tags(spec, architecture)

    Enum.all?(machines, fn machine ->
      Enum.all?(machine.exports, fn {_id, export} ->
        destination = export.spec.destination

        destination.registry != target.registry or destination.repository != target.repository or
          Enum.all?(
            ExportSpec.tags(export.spec, machine.spec.artifact["architecture"]),
            &(&1 not in tags)
          )
      end)
    end)
  end

  defp error(category), do: {:error, %Error{category: category, operation: :export}}
end
