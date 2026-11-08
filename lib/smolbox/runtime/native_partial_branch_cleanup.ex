defmodule SmolBox.Runtime.NativePartialBranchCleanup do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Backend.{Budget, EmbeddedPartialBranchCleanup}

  alias SmolBox.Embedded.{
    NativePartialBranchCleanupCandidate,
    NativePartialBranchCleanupResolutionResult,
    NativePartialBranchCleanupResult,
    NativePartialBranchDisposal,
    NativePartialBranchDisposalResult
  }

  alias SmolBox.Runtime.{MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child, version) do
    with :ok <- ManagedMachine.validate(child),
         true <- matching_version?(child, version) do
      case action(child) do
        %{proof: proof} when not is_nil(proof) -> {:ok, child}
        %{unneeded: proof} when not is_nil(proof) -> {:ok, child}
        _ -> completed_or_begin(config, coordinator, child, version)
      end
    else
      false -> Session.error(:stale_version, :branch)
      error -> error
    end
  end

  defp completed_or_begin(config, coordinator, child, version) do
    case child.branch.native_authority.partial_disposal do
      %{proof: proof, cleanup: nil} when not is_nil(proof) -> {:ok, child}
      _ -> begin(config, coordinator, child, version)
    end
  end

  defp begin(config, coordinator, child, version) do
    with true <- eligible?(child),
         {:ok, %{kind: :embedded} = worker} <- MachineSession.worker(config, child),
         :ok <- Target.require_operation(worker, :cleanup_partial_branch_disposal),
         :ok <- require_qualification(worker, child),
         {:ok, budget} <- constrain(Target.connection(worker).budget) do
      deadline = now() + budget.timeout_ms
      fenced(config, coordinator, child, version, worker, budget, deadline)
    else
      false -> Session.error(:unsupported_capability, :branch)
      {:ok, _} -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp eligible?(child),
    do:
      NativePartialBranchDisposal.eligible?(child) and
        match?(%{proof: nil}, child.branch.native_authority.partial_disposal)

  defp fenced(config, coordinator, child, version, worker, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         true <- NativePartialBranchDisposal.pending?(parent, child) do
      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        :deleted,
        fn pinned ->
          prepare(config, parent, child, version, pinned, budget, deadline)
        end,
        deadline
      )
    else
      false -> Session.error(:identity_conflict, :branch)
      error -> error
    end
  end

  defp require_qualification(worker, child) do
    if action(child) == nil,
      do: Target.require_operation(worker, :qualify_partial_branch_cleanup),
      else: :ok
  end

  defp prepare(config, parent, child, version, worker, budget, deadline) do
    if action(child) == nil,
      do: qualify(config, parent, child, version, worker, budget, deadline),
      else: resume_accepted(config, child, version, worker, budget, deadline)
  end

  defp qualify(config, parent, child, version, worker, budget, deadline) do
    with {:ok, stage, rest} <- reserve_qualification(budget, deadline) do
      response =
        invoke(config, parent, child, worker, :qualify_partial_branch_cleanup, stage, deadline)

      qualified(response, {config, parent, child, version, worker, rest, deadline})
    end
  end

  defp qualified(
         {:native_response, {:ok, %NativePartialBranchCleanupCandidate{} = result}},
         {config, parent, child, version, worker, rest, deadline}
       ) do
    if candidate_bound?(result, parent, child, worker),
      do: accept_candidate(config, child, version, worker, rest, deadline),
      else: uncertain(Session.error(:identity_conflict, :branch))
  end

  defp qualified(
         {:native_response, {:ok, %NativePartialBranchDisposalResult{} = result}},
         {config, parent, child, _version, worker, _rest, deadline}
       ),
       do: complete(config, parent, child, result, worker, deadline)

  defp qualified(response, _), do: error_response(response)

  defp accept_candidate(config, child, version, worker, budget, deadline) do
    with {:ok, budget} <- cleanup_budget(budget),
         do: accept(config, child, version, worker, budget, deadline)
  end

  defp resume_accepted(config, child, version, worker, budget, deadline) do
    with {:ok, budget} <-
           Budget.constrain(budget, max_request_bytes: 64 * 1024, max_response_bytes: 192 * 1024),
         do: accept(config, child, version, worker, budget, deadline)
  end

  defp accept(config, child, version, worker, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         {:ok, _} <- remaining(deadline),
         {:ok, accepted} <-
           MachineSession.store(config, :branch_advance, [
             child.branch.source,
             Session.guard(current),
             child.id,
             child.branch.state,
             {:accept_partial_disposal_cleanup, version, platform(worker)},
             config.clock.now()
           ]) do
      perform(config, accepted, worker, budget, deadline)
    end
  end

  # Every retry keeps the saved cleanup action. The backend may only inspect
  # original unnecessary-cleanup history after a definitive non-dispatch reply.
  # No SDK disposal or removal fallback follows that history check.
  defp perform(config, child, worker, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source) do
      case invoke(
             config,
             parent,
             child,
             worker,
             :cleanup_partial_branch_disposal,
             budget,
             deadline
           ) do
        {:native_response, {:ok, %NativePartialBranchCleanupResult{} = result}} ->
          complete(config, parent, child, result, worker, deadline)

        {:native_response, {:ok, %NativePartialBranchCleanupResolutionResult{} = result}} ->
          complete(config, parent, child, result, worker, deadline)

        response ->
          error_response(response)
      end
    end
  end

  defp invoke(config, parent, child, worker, operation, budget, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      budget = %{budget | timeout_ms: min(budget.timeout_ms, timeout)}
      reference = %{Target.connection(worker, parent) | budget: budget}
      io_record = %{parent | operation_deadline_ms: config.clock.now() + budget.timeout_ms}

      MachineSession.io(config, io_record, fn ->
        {:native_response, Backend.invoke(reference, operation, [parent, child])}
      end)
    end
  end

  defp error_response({:native_response, {:error, %Error{} = error}}), do: {:error, error}
  defp error_response({:error, %Error{}} = error), do: uncertain(error)
  defp error_response(_), do: uncertain(Session.error(:identity_conflict, :branch))

  defp complete(config, parent, child, result, worker, deadline) do
    completed =
      with true <- result_bound?(result, parent, child, worker),
           {:ok, _} <- remaining(deadline),
           {:ok, current} <- MachineSession.claim(config, child.branch.source),
           {:ok, _} <- remaining(deadline),
           do:
             MachineSession.store(config, :branch_resolve, [
               child.branch.source,
               Session.guard(current),
               child.id,
               result.source,
               result,
               config.clock.now()
             ]),
           else: (
             false -> Session.error(:identity_conflict, :branch)
             error -> error
           )

    completed =
      with {:ok, record} <- completed,
           {:ok, _} <- remaining(deadline),
           do: {:ok, record}

    uncertain(completed)
  end

  defp result_bound?(%NativePartialBranchCleanupResult{} = result, parent, child, worker) do
    context = Target.connection(worker).context
    publication = result.proof.disposal["publication"]

    NativePartialBranchCleanupResult.bound?(result, parent, child) and
      get_in(publication, ~w(change child_origin intent epoch)) == context.epoch and
      publication["change"]["platform"] == platform(worker)
  end

  defp result_bound?(
         %NativePartialBranchCleanupResolutionResult{} = result,
         parent,
         child,
         worker
       ) do
    context = Target.connection(worker).context
    publication = result.proof.disposal["publication"]

    NativePartialBranchCleanupResolutionResult.bound?(result, parent, child) and
      EmbeddedPartialBranchCleanup.resolution_supported?(context) and
      get_in(publication, ~w(change child_origin intent epoch)) == context.epoch and
      publication["change"]["platform"] == platform(worker)
  end

  defp result_bound?(%NativePartialBranchDisposalResult{} = result, parent, child, worker),
    do:
      NativePartialBranchDisposalResult.bound?(result, parent, child) and
        original_epoch?(result.proof, worker)

  defp candidate_bound?(result, parent, child, worker),
    do:
      NativePartialBranchCleanupCandidate.bound?(result, parent, child) and
        original_epoch?(result.proof, worker)

  defp original_epoch?(proof, worker),
    do:
      get_in(proof.publication, ~w(change child_origin intent epoch)) ==
        Target.connection(worker).context.epoch and
        proof.publication["change"]["platform"] == platform(worker)

  defp action(child) do
    case child.branch.native_authority.partial_disposal do
      %{cleanup: saved} -> saved
      _ -> nil
    end
  end

  defp matching_version?(child, version) do
    saved = action(child)
    disposal = child.branch.native_authority.partial_disposal

    version == child.version or saved_version?(saved, version) or
      (disposal != nil and disposal.proof != nil and disposal.cleanup == nil and
         version in [disposal.version, disposal.completion_version])
  end

  defp saved_version?(%{version: saved, completion_version: completed}, version),
    do: version == saved or (completed != nil and version == completed)

  defp saved_version?(_, _), do: false

  defp reserve_qualification(budget, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         {:ok, stage} <-
           Budget.constrain(budget,
             timeout_ms: timeout,
             max_request_bytes: 26 * 1024,
             max_response_bytes: 64 * 1024
           ) do
      {:ok, stage,
       %{
         budget
         | max_request_bytes: budget.max_request_bytes - stage.max_request_bytes,
           max_response_bytes: budget.max_response_bytes - stage.max_response_bytes
       }}
    end
  end

  # Reserve a complete bounded cleanup/observation stage before durable acceptance.
  # Qualification may instead return the original terminal disposition and use no grant.
  defp cleanup_budget(budget) do
    if budget.max_request_bytes >= 32 * 1024 and budget.max_response_bytes >= 96 * 1024,
      do: Budget.constrain(budget, max_request_bytes: 32 * 1024, max_response_bytes: 96 * 1024),
      else: Session.error(:output_limit, :branch)
  end

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 64 * 1024,
        max_response_bytes: 192 * 1024
      )

  defp remaining(deadline) do
    timeout = deadline - now()
    if timeout > 0, do: {:ok, timeout}, else: Session.error(:expired, :branch)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | evidence: :dispatch_uncertain, operation: :branch}}

  defp uncertain(value), do: value
  defp platform(worker), do: Atom.to_string(Target.connection(worker).context.config.platform)
  defp now, do: System.monotonic_time(:millisecond)
end
