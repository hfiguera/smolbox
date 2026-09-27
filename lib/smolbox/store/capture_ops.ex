defmodule SmolBox.Store.CaptureOps do
  @moduledoc """
  Atomic capture transactions. Adapters serialize history, ownership, machine
  exclusion and worker usage. Every artifact reservation survives source deletion.
  """
  alias SmolBox.{
    CheckpointCapture,
    CheckpointCaptureSpec,
    Error,
    Machine,
    ManagedMachine,
    Validation
  }

  def accept(machine, spec, fingerprint, capacity, usage, now) do
    with :ok <- CheckpointCaptureSpec.validate(spec), true <- Validation.digest?(fingerprint) do
      case machine.captures[spec.id] do
        %CheckpointCapture{fingerprint: ^fingerprint} -> {:ok, machine}
        %CheckpointCapture{} -> error(:identity_conflict)
        nil -> insert(machine, spec, fingerprint, capacity, usage, now)
      end
    else
      _ -> error(:validation)
    end
  end

  defp insert(m, spec, fingerprint, capacity, usage, now) do
    needed = spec.policy.resources
    profile = m.spec.profile

    disk_floor =
      2 * (profile.storage_gb + profile.overlay_gb) + div(profile.memory_mb + 1023, 1024) +
        div(spec.policy.max_bytes + 1_073_741_823, 1_073_741_824)

    with true <- m.state == :running and ManagedMachine.idle?(m) and m.spec.checkpointable,
         true <- map_size(m.captures) < 256,
         true <- needed.disk_gb >= disk_floor and needed.memory_mb >= profile.memory_mb,
         true <- is_map(capacity) and Map.keys(capacity) == Map.keys(needed),
         true <-
           Enum.all?(needed, fn {key, value} ->
             is_integer(capacity[key]) and is_integer(usage[key]) and
               usage[key] + value <= capacity[key]
           end),
         {:ok, capture} <- CheckpointCapture.new(ManagedMachine.key(m), spec, fingerprint, now) do
      ManagedMachine.update(
        m,
        %{
          captures: Map.put(m.captures, spec.id, capture),
          active_capture: spec.id,
          operation: :capture,
          phase: :pending,
          operation_deadline_ms: capture.deadline_ms,
          next_due_at_ms: now
        },
        now
      )
    else
      _ -> error(:admission_exhausted)
    end
  end

  def advance(m, id, expected, changes, now) do
    with %CheckpointCapture{} = r <- m.captures[id],
         true <- m.active_capture == id and r.state == expected,
         true <- Validation.keys?(changes, [:state, :result, :error, :resolved_at_ms]),
         true <- allowed?(r.state, changes[:state]),
         true <-
           changes[:state] != :failed or r.state == :accepted or
             match?(%Error{evidence: :not_dispatched}, changes[:error]),
         true <- r.result == nil or Keyword.get(changes, :result, r.result) == r.result,
         next =
           struct!(
             r,
             changes ++ [version: r.version + 1, updated_at_ms: max(now, r.updated_at_ms)]
           ),
         :ok <- CheckpointCapture.validate(next),
         true <- next.result == nil or next.result.profile == m.spec.profile do
      save(m, next, now)
    else
      _ -> error(:stale_version)
    end
  end

  def cancel(m, id, now) do
    case m.captures[id] do
      %CheckpointCapture{state: :accepted} ->
        advance(m, id, :accepted, [state: :cancelled], now)

      %CheckpointCapture{state: :dispatching} ->
        advance(
          m,
          id,
          :dispatching,
          [
            state: :unknown,
            error: %Error{category: :unknown, operation: :checkpoint, evidence: :unknown}
          ],
          now
        )

      %CheckpointCapture{} ->
        {:ok, m}

      nil ->
        error(:not_found)
    end
  end

  def resolve(m, id, :absent, now) do
    with %CheckpointCapture{state: state} <- m.captures[id],
         true <- state in [:captured, :unknown],
         {:ok, saved} <-
           advance(
             m,
             id,
             state,
             [
               state: if(state == :captured, do: :completed, else: :resolved_unknown),
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
      _ -> error(:identity_conflict)
    end
  end

  def resolve(m, id, observed, now) do
    with %CheckpointCapture{state: state} <- m.captures[id],
         true <- state in [:captured, :unknown],
         true <-
           observed.state in [:running, :stopped] and
             Machine.same_incarnation?(m.created_machine, observed),
         {:ok, saved} <-
           advance(
             m,
             id,
             state,
             [
               state: if(state == :captured, do: :completed, else: :resolved_unknown),
               resolved_at_ms: now
             ],
             now
           ) do
      ManagedMachine.update(
        saved,
        %{state: observed.state, observed_machine: observed, last_error: nil},
        now
      )
    else
      _ -> error(:identity_conflict)
    end
  end

  def release(m, id, now) do
    case m.captures[id] do
      %CheckpointCapture{state: state} = r when state in [:completed, :resolved_unknown] ->
        next = %{
          r
          | released_at_ms: r.released_at_ms || now,
            updated_at_ms: max(now, r.updated_at_ms),
            version: r.version + 1
        }

        ManagedMachine.update(m, %{captures: Map.put(m.captures, id, next)}, now)

      _ ->
        error(:identity_conflict)
    end
  end

  defp save(m, r, now) do
    done = CheckpointCapture.terminal?(r)

    ManagedMachine.update(
      m,
      %{
        captures: Map.put(m.captures, r.spec.id, r),
        active_capture: if(done, do: nil, else: r.spec.id),
        operation: if(done, do: nil, else: :capture),
        phase: if(done, do: nil, else: phase(r.state)),
        state: if(r.state == :unknown, do: :unknown, else: m.state),
        operation_deadline_ms: if(done, do: nil, else: r.deadline_ms),
        next_due_at_ms: if(done or r.state in [:captured, :unknown], do: now + 60_000, else: now)
      },
      now
    )
  end

  defp phase(:accepted), do: :pending
  defp phase(:dispatching), do: :dispatching
  defp phase(_), do: :uncertain
  defp allowed?(:accepted, next), do: next in [:dispatching, :failed, :cancelled]
  defp allowed?(:dispatching, next), do: next in [:captured, :unknown, :failed]
  defp allowed?(:captured, :completed), do: true
  defp allowed?(:unknown, :resolved_unknown), do: true
  defp allowed?(_, _), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :checkpoint}}
end
