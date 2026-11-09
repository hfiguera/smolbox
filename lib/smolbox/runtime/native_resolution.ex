defmodule SmolBox.Runtime.NativeResolution do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext}
  alias SmolBox.{CheckpointCapture, Error, ManagedMachine}

  alias SmolBox.Embedded.{
    BranchCompletion,
    Call,
    CaptureTransition,
    NativeBranchDeletion,
    NativeBranchDeletionAction,
    NativeCapture,
    NativePreparedBranchRetirement
  }

  alias SmolBox.Runtime.{NativeAuthority, Session, Target}

  def run(config, coordinator, record, target, disposition, function, deadline \\ nil)

  # A lost receipt can prove only absence. Stopped resolution cannot recover
  # material identity or substitute matching SDK labels for creation authority.
  def run(
        _config,
        _coordinator,
        %{created_machine: nil},
        %{kind: :embedded},
        :stopped,
        _function,
        _deadline
      ),
      do: Session.error(:unsupported_capability, :reconcile)

  def run(
        config,
        coordinator,
        record,
        %{kind: :embedded} = target,
        disposition,
        function,
        deadline
      ) do
    Session.safe(fn ->
      deadline = deadline || now() + min(target.connection.budget.timeout_ms, 30_000)
      target = Target.pin(target)

      control(config, coordinator, record, target, disposition, function, deadline)
    end)
  end

  def run(_config, _coordinator, _record, worker, _disposition, function, _deadline),
    do: function.(worker)

  defp control(
         config,
         coordinator,
         record,
         target,
         {:ordinary_branch, operation},
         function,
         deadline
       )
       when operation in [
              :branch_retire,
              :branch_release_storage,
              :branch_resolve_ready,
              :resolve_branch_deletion,
              :retire_prepared_branch
            ],
       do: ordinary_control(config, coordinator, record, target, operation, function, deadline)

  defp control(
         config,
         coordinator,
         record,
         target,
         {:branch_deletion_action, _} = operation,
         function,
         deadline
       ),
       do: ordinary_control(config, coordinator, record, target, operation, function, deadline)

  defp control(
         config,
         coordinator,
         record,
         target,
         {:ordinary_capture, :capture_complete},
         function,
         deadline
       ),
       do:
         ordinary_control(
           config,
           coordinator,
           record,
           target,
           :capture_complete,
           function,
           deadline
         )

  defp control(config, coordinator, _record, target, _disposition, function, deadline),
    do:
      NativeAuthority.run(coordinator, target.id, fn ->
        resolve(config, target, function, deadline)
      end)

  defp ordinary_control(config, coordinator, record, target, operation, function, deadline) do
    NativeAuthority.operation(coordinator, target.id, fn was_ready ->
      healthy = was_ready and same_owner(target, deadline, [:ready]) == :ok

      {result, lease} = branch_control(config, target, function, deadline)

      restored =
        healthy and reusable_result?(result, operation, record, target) and lease != nil and
          Map.get(record, :worker_generation) == lease.generation and
          restore(config, target, deadline, lease) == :ok

      # A committed proof remains the returned result even if later activation
      # cannot be confirmed. In that case the coordinator stays frozen.
      {result, restored}
    end)
  end

  defp branch_control(config, target, function, deadline) do
    with :ok <- await_quiesced(target, deadline),
         {:ok, lease} <- control_lease(config, target),
         {:ok, bounded} <- bounded(quiesced(target), deadline),
         do: {function.(bounded), lease},
         else: (error -> {error, nil})
  end

  # A completed managed operation can still be draining its final Port record.
  # Quiescence already fences new mutations. Wait only on a known busy rejection,
  # under the same authority barrier, pinned epoch and captured deadline; never
  # replay the operation callback or a possibly dispatched bridge request.
  defp await_quiesced(target, deadline) do
    context = target.connection.context

    with {:ok, bounded} <- bounded(target, deadline) do
      case EmbeddedContext.bridge(context).quiesce(
             context.server,
             context.epoch,
             bounded.connection.budget.timeout_ms
           ) do
        {:error, %Error{category: :admission_exhausted, evidence: :not_dispatched}} ->
          Process.sleep(min(25, max(0, deadline - now())))
          await_quiesced(target, deadline)

        result ->
          result
      end
    end
  end

  # Explicit recovery may preserve a completed scan only after its paired store
  # commit returns the validated original child. A rejection, material-only
  # publication or uncertain/partial result cannot activate this path.
  defp reusable_result?(
         {:ok,
          %ManagedMachine{
            state: :deleted,
            branch: %{
              state: :closed,
              native_authority: %{prepared_retirement: %NativePreparedBranchRetirement{} = saved}
            }
          } = child},
         :retire_prepared_branch,
         parent,
         target
       ) do
    ManagedMachine.validate(child) == :ok and
      child.id == parent.active_branch and child.branch.source == ManagedMachine.key(parent) and
      child.worker_id == target.id and child.worker_generation == parent.worker_generation and
      saved.proof.retirement["intent"]["epoch"] == target.connection.context.epoch
  end

  defp reusable_result?(
         {:ok,
          %ManagedMachine{
            branch: %{state: state, native_authority: %{completion: %BranchCompletion{} = proof}}
          } = child},
         :branch_resolve_ready,
         parent,
         target
       )
       when state in [:held, :ready] do
    ManagedMachine.validate(child) == :ok and
      child.branch.source == ManagedMachine.key(parent) and child.worker_id == target.id and
      get_in(proof.publication, ~w(change child_origin intent epoch)) ==
        target.connection.context.epoch
  end

  defp reusable_result?(
         {:ok,
          %ManagedMachine{
            state: :deleted,
            branch: %{native_authority: %{deletion: %{proof: proof} = deletion}}
          } = child},
         :resolve_branch_deletion,
         original,
         target
       ) do
    same_branch_child?(child, original, target) and
      NativeBranchDeletion.matches?(deletion, proof)
  end

  defp reusable_result?(result, {:branch_deletion_action, action}, original, target) do
    with {:ok, %ManagedMachine{branch: %{native_authority: %{} = authority}} = child} <- result,
         %{proof: proof} = saved <- Map.get(authority, NativeBranchDeletionAction.field(action)),
         true <- same_branch_child?(child, original, target),
         true <- NativeBranchDeletionAction.matches?(saved, action, proof) do
      case action do
        :collect -> child.state == :unknown and child.reservation == original.reservation
        _ -> child.state == :deleted and child.reservation == nil
      end
    else
      _ -> false
    end
  end

  # A normal completed capture already committed its material transition. Keep
  # the same ready owner's scan only for that exact captured result, after its
  # native observation and atomic store resolution. Unknown capture recovery
  # continues through the generic frozen path.
  defp reusable_result?(
         {:ok, %CheckpointCapture{state: :completed} = completed},
         :capture_complete,
         %ManagedMachine{} = record,
         target
       ) do
    original = record.captures[completed.spec.id]
    mutable = [:state, :version, :updated_at_ms, :resolved_at_ms]

    with %CheckpointCapture{state: :captured, native_transition: %CaptureTransition{} = proof} <-
           original,
         true <- ManagedMachine.validate(record) == :ok,
         true <- record.worker_id == target.id,
         true <- proof.previous["target_id"] == target.domain_binding.target_id,
         true <- proof.previous["domain_generation"] == target.domain_binding.generation,
         true <- CheckpointCapture.validate(original) == :ok,
         true <- CheckpointCapture.validate(completed) == :ok,
         true <- completed.machine == ManagedMachine.key(record),
         true <- completed.version == original.version + 1,
         true <- Map.drop(completed, mutable) == Map.drop(original, mutable) do
      CaptureTransition.bound?(
        proof,
        original.native_source_receipt,
        original.spec.id,
        NativeCapture.request(original)
      )
    else
      _ -> false
    end
  end

  defp reusable_result?(_, :capture_complete, _, _), do: false
  defp reusable_result?(_, :branch_resolve_ready, _, _), do: false
  defp reusable_result?(_, :resolve_branch_deletion, _, _), do: false
  defp reusable_result?(_, :retire_prepared_branch, _, _), do: false
  defp reusable_result?({:ok, _}, _, _, _), do: true
  defp reusable_result?({:error, %Error{evidence: :not_dispatched}}, _, _, _), do: true
  defp reusable_result?(_, _, _, _), do: false

  defp same_branch_child?(
         %{branch: %{native_authority: %{completion: %BranchCompletion{} = completion}}} = child,
         original,
         target
       ) do
    ManagedMachine.validate(child) == :ok and
      ManagedMachine.key(child) == ManagedMachine.key(original) and
      child.worker_id == target.id and child.worker_generation == original.worker_generation and
      child.branch.source == original.branch.source and
      completion == original.branch.native_authority.completion and
      get_in(completion.publication, ~w(change child_origin intent epoch)) ==
        target.connection.context.epoch
  end

  defp same_branch_child?(_, _, _), do: false

  defp restore(config, target, deadline, %{owner: owner, generation: generation}) do
    context = target.connection.context
    bridge = EmbeddedContext.bridge(context)

    with :ok <- same_owner(target, deadline, [:ready, :reconciling]),
         {:ok, %{owner: ^owner, generation: ^generation}} <- control_lease(config, target),
         {:ok, bounded} <- bounded(target, deadline),
         :ok <-
           bridge.activate(
             context.server,
             target.domain_binding,
             context.epoch,
             bounded.connection.budget.timeout_ms
           ),
         do: same_owner(target, deadline, [:ready])
  end

  defp control_lease(config, target) do
    with {:ok, %{owner: owner, generation: generation, until_ms: until_ms} = lease} <-
           lease(config, target),
         true <-
           owner == config.owner and
             SmolBox.Validation.integer?(generation, 1, 9_007_199_254_740_991) and
             is_integer(until_ms) and until_ms > config.clock.now(),
         do: {:ok, lease},
         else: (_ -> Session.error(:stale_claim, :reconcile))
  end

  defp same_owner(target, deadline, statuses) do
    context = target.connection.context

    with {:ok, bounded} <- bounded(target, deadline),
         budget = %{
           bounded.connection.budget
           | timeout_ms: min(bounded.connection.budget.timeout_ms, 1000)
         },
         {:ok, %{status: status, epoch: epoch}} <- Call.health(context, budget),
         true <- status in statuses and epoch == context.epoch,
         do: :ok,
         else: (_ -> Session.error(:unknown, :reconcile))
  end

  defp bounded(target, deadline) do
    with remaining when remaining > 0 <- deadline - now(),
         {:ok, budget} <- Budget.constrain(target.connection.budget, timeout_ms: remaining),
         do: {:ok, %{target | connection: %{target.connection | budget: budget}}},
         else: (_ -> Session.error(:expired, :reconcile))
  end

  defp resolve(config, target, function, deadline) do
    with :ok <- await_quiesced(target, deadline),
         {:ok, bounded} <- bounded(target, deadline),
         {:ok, _lease} <- lease(config, bounded),
         {:ok, bounded} <- bounded(quiesced(bounded), deadline),
         do: function.(bounded)
  end

  defp lease(config, target),
    do:
      Session.store(config, :claim_worker, [
        target.id,
        config.owner,
        config.clock.now(),
        config.lease_ms
      ])

  defp now, do: System.monotonic_time(:millisecond)

  defp quiesced(%{connection: %{context: %EmbeddedContext{} = context} = reference} = target),
    do: %{target | connection: %{reference | context: %{context | quiesced: true}}}

  defp quiesced(target), do: target
end
