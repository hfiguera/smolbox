defmodule SmolBox.Store.CaptureOps do
  @moduledoc """
  Atomic capture transactions. Adapters serialize history, ownership, machine
  exclusion and worker usage. Every artifact reservation survives source deletion.
  """
  alias SmolBox.Embedded.{
    CaptureResolutionTransition,
    CaptureTransition,
    Identity,
    NativeCapture,
    NativeCaptureCleanup,
    NativeCaptureResolution,
    NativeGrowth
  }

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
    profile = if native?(m), do: SmolBox.DiskExpansion.profile(m), else: m.spec.profile

    disk_floor =
      2 * (profile.storage_gb + profile.overlay_gb) + div(profile.memory_mb + 1023, 1024) +
        div(spec.policy.max_bytes + 1_073_741_823, 1_073_741_824)

    with true <- m.branch == nil and SmolBox.Branch.children_retired?(m),
         true <- m.state == :running and ManagedMachine.idle?(m) and m.spec.checkpointable,
         true <- map_size(m.captures) < 256,
         true <- id_available?(m, spec.id),
         true <- needed.disk_gb >= disk_floor and needed.memory_mb >= profile.memory_mb,
         true <- is_map(capacity) and Map.keys(capacity) == Map.keys(needed),
         true <-
           Enum.all?(needed, fn {key, value} ->
             is_integer(capacity[key]) and is_integer(usage[key]) and
               usage[key] + value <= capacity[key]
           end),
         {:ok, receipt} <- capture_source(m),
         {:ok, capture} <- CheckpointCapture.new(ManagedMachine.key(m), spec, fingerprint, now) do
      capture = %{capture | native_source_receipt: receipt}

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

  defp capture_source(m) do
    if native?(m) do
      with {:ok, receipt, _, _} <- NativeGrowth.head(m), do: {:ok, receipt}
    else
      {:ok, nil}
    end
  end

  def advance(m, id, expected, changes, now) do
    with %CheckpointCapture{} = r <- m.captures[id],
         true <- m.active_capture == id and r.state == expected,
         true <- Validation.keys?(changes, fields(m)),
         true <- allowed?(r.state, changes[:state]),
         true <-
           changes[:state] != :failed or r.state == :accepted or
             match?(%Error{evidence: :not_dispatched}, changes[:error]),
         true <- r.result == nil or Keyword.get(changes, :result, r.result) == r.result,
         true <-
           r.native_transition == nil or
             Keyword.get(changes, :native_transition, r.native_transition) == r.native_transition,
         next =
           struct!(
             r,
             changes ++ [version: r.version + 1, updated_at_ms: max(now, r.updated_at_ms)]
           ),
         :ok <- CheckpointCapture.validate(next),
         true <-
           next.result == nil or
             next.result.profile ==
               if(native?(m), do: SmolBox.DiskExpansion.profile(m), else: m.spec.profile),
         {:ok, observed} <- native_observation(m, r, next) do
      save(m, next, now, observed)
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

  def resolve(
        %{backend_assignment: %{version: 2}} = m,
        id,
        %NativeCaptureResolution{} = resolution,
        now
      ) do
    with %CheckpointCapture{state: :unknown} = capture <- m.captures[id],
         true <- NativeCapture.resolution_valid?(m, capture, resolution),
         next = %{
           capture
           | state: :resolved_unknown,
             native_abort_source: resolution.qualification,
             resolved_at_ms: now,
             updated_at_ms: max(now, capture.updated_at_ms),
             version: capture.version + 1
         },
         :ok <- CheckpointCapture.validate(next),
         {:ok, saved} <- save(m, next, now, resolution.observed) do
      ManagedMachine.update(
        saved,
        %{
          state: resolution.observed.state,
          observed_machine: resolution.observed,
          last_error: nil
        },
        now
      )
    else
      _ -> error(:identity_conflict)
    end
  end

  def resolve(_m, _id, %NativeCaptureResolution{}, _now), do: error(:identity_conflict)

  def resolve(
        %{backend_assignment: %{version: 2}} = m,
        id,
        %Machine{backend_identity: %Identity{transition: %{__struct__: type}} = identity} =
          observed,
        now
      )
      when type in [CaptureTransition, CaptureResolutionTransition] do
    case m.captures[id] do
      %CheckpointCapture{state: :unknown} = capture ->
        with true <- NativeCapture.resolution_valid?(m, capture, observed),
             next = %{
               capture
               | state: :resolved_unknown,
                 native_transition: identity.transition,
                 resolved_at_ms: now,
                 updated_at_ms: max(now, capture.updated_at_ms),
                 version: capture.version + 1
             },
             :ok <- CheckpointCapture.validate(next),
             {:ok, saved} <- save(m, next, now, observed) do
          ManagedMachine.update(
            saved,
            %{state: observed.state, observed_machine: observed, last_error: nil},
            now
          )
        else
          _ -> error(:identity_conflict)
        end

      _ ->
        resolve_present(m, id, observed, now)
    end
  end

  def resolve(m, id, observed, now), do: resolve_present(m, id, observed, now)

  defp resolve_present(m, id, observed, now) do
    with %CheckpointCapture{state: state} <- m.captures[id],
         true <- state in [:captured, :unknown] and (not native?(m) or state != :unknown),
         true <-
           observed.state in [:running, :stopped] and
             source_matches?(m, observed),
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
    if native?(m) do
      case m.captures[id] do
        %CheckpointCapture{released_at_ms: at, state: state}
        when not is_nil(at) and state in [:completed, :resolved_unknown] ->
          {:ok, m}

        _ ->
          error(:identity_conflict)
      end
    else
      release_record(m, id, nil, now)
    end
  end

  def release(m, id, %NativeCaptureCleanup{} = proof, now) do
    with true <- native?(m),
         %CheckpointCapture{state: state} = capture <- m.captures[id],
         true <- state in [:completed, :resolved_unknown],
         {:ok, previous} <- NativeCapture.source_receipt(m, capture),
         true <- NativeCaptureCleanup.bound?(proof, capture, previous),
         true <- capture.native_cleanup == nil or capture.native_cleanup == proof do
      if capture.released_at_ms != nil and capture.native_cleanup == proof,
        do: {:ok, m},
        else: release_record(m, id, proof, now)
    else
      _ -> error(:identity_conflict)
    end
  end

  def release(_, _, _, _), do: error(:identity_conflict)

  defp release_record(m, id, proof, now) do
    case m.captures[id] do
      %CheckpointCapture{state: state} = r when state in [:completed, :resolved_unknown] ->
        next = %{
          r
          | native_cleanup: proof,
            native_source_receipt: r.native_source_receipt || (proof && proof.receipt.previous),
            released_at_ms: r.released_at_ms || now,
            updated_at_ms: max(now, r.updated_at_ms),
            version: r.version + 1
        }

        ManagedMachine.update(m, %{captures: Map.put(m.captures, id, next)}, now)

      _ ->
        error(:identity_conflict)
    end
  end

  defp save(m, r, now, observed) do
    done = CheckpointCapture.terminal?(r)

    ManagedMachine.update(
      m,
      %{
        captures: Map.put(m.captures, r.spec.id, r),
        observed_machine: observed,
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

  defp native?(%{backend_assignment: %{version: 2}}), do: true
  defp native?(_), do: false

  defp id_available?(m, id),
    do:
      not native?(m) or
        (not Map.has_key?(m.disk_expansions, id) and not Map.has_key?(m.native_branch_history, id))

  defp fields(m),
    do:
      [:state, :result, :error, :resolved_at_ms] ++
        if(native?(m), do: [:native_transition], else: [])

  defp source_matches?(m, observed),
    do:
      Machine.same_incarnation?(
        if(native?(m), do: SmolBox.DiskExpansion.expected(m), else: m.created_machine),
        observed
      )

  defp native_observation(
         m,
         %{native_transition: nil},
         %{native_transition: %CaptureTransition{} = proof} = next
       ) do
    with true <- native?(m),
         {:ok, receipt, _sizes, _last} <- NativeGrowth.head(m),
         true <-
           CaptureTransition.bound?(proof, receipt, next.spec.id, %{
             "max_bytes" => next.spec.policy.max_bytes,
             "idle" => next.spec.idle
           }),
         %Machine{state: :running, backend_identity: %Identity{pid_identity: pid}} = observed <-
           m.observed_machine,
         true <- pid == proof.change["intent"]["source_pid"],
         {:ok, history} <- NativeGrowth.transitions(m) do
      {:ok,
       %{
         observed
         | backend_identity: %Identity{
             receipt: proof.receipt,
             pid_identity: pid,
             transition: proof,
             material_history: history ++ [proof]
           }
       }}
    else
      _ -> error(:identity_conflict)
    end
  end

  defp native_observation(m, _previous, %{native_transition: nil, state: state})
       when state in [:captured, :completed] do
    if native?(m), do: error(:identity_conflict), else: {:ok, m.observed_machine}
  end

  defp native_observation(m, _previous, _next), do: {:ok, m.observed_machine}
  defp phase(:dispatching), do: :dispatching
  defp phase(:accepted), do: :pending
  defp phase(_), do: :uncertain
  defp allowed?(:accepted, next), do: next in [:dispatching, :failed, :cancelled]
  defp allowed?(:dispatching, next), do: next in [:captured, :unknown, :failed]
  defp allowed?(:captured, :completed), do: true
  defp allowed?(:unknown, :resolved_unknown), do: true
  defp allowed?(_, _), do: false
  defp error(category), do: {:error, %Error{category: category, operation: :checkpoint}}
end
