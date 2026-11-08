defmodule SmolBox.Runtime.NativePartialBranchDisposal do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Backend.Budget
  alias SmolBox.Embedded.NativePartialBranchDisposal, as: Disposal
  alias SmolBox.Embedded.NativePartialBranchDisposalResult
  alias SmolBox.Runtime.{MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child, version) do
    with :ok <- ManagedMachine.validate(child),
         true <- matching_version?(child, version) do
      case child.branch.native_authority.partial_disposal do
        %{proof: proof} when not is_nil(proof) -> {:ok, child}
        %{cleanup: cleanup} when not is_nil(cleanup) -> Session.error(:identity_conflict, :branch)
        _ -> begin(config, coordinator, child, version)
      end
    else
      false -> Session.error(:stale_version, :branch)
      error -> error
    end
  end

  defp begin(config, coordinator, child, version) do
    with true <- Disposal.eligible?(child),
         {:ok, %{kind: :embedded} = worker} <- MachineSession.worker(config, child),
         :ok <- Target.require_operation(worker, :dispose_partial_branch),
         :ok <- Target.require_operation(worker, :resolve_partial_branch_disposal) do
      budget = Target.connection(worker).budget
      deadline = now() + min(budget.timeout_ms, 30_000)
      fenced(config, coordinator, child, version, worker, budget, deadline)
    else
      false -> Session.error(:unsupported_capability, :branch)
      {:ok, _} -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp fenced(config, coordinator, child, version, worker, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         true <- Disposal.pending?(parent, child) do
      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        :deleted,
        fn pinned ->
          accept(config, child, version, pinned, budget, deadline)
        end,
        deadline
      )
    else
      false -> Session.error(:identity_conflict, :branch)
      error -> error
    end
  end

  defp accept(config, child, version, worker, budget, deadline) do
    fresh = child.branch.native_authority.partial_disposal == nil

    with {:ok, _} <- remaining(deadline),
         {:ok, current} <- MachineSession.claim(config, child.branch.source),
         {:ok, _} <- remaining(deadline),
         {:ok, accepted} <-
           MachineSession.store(config, :branch_advance, [
             child.branch.source,
             Session.guard(current),
             child.id,
             child.branch.state,
             {:accept_partial_disposal, version, platform(worker)},
             config.clock.now()
           ]) do
      if fresh,
        do: dispatch(config, accepted, worker, budget, deadline),
        else: resume(config, accepted, worker, budget, deadline)
    end
  end

  defp dispatch(config, child, worker, budget, deadline),
    do: stage(config, child, worker, :dispose_partial_branch, budget, deadline)

  # An uncertain observation never falls through to deletion. A not-dispatched
  # state may re-offer only this saved action; the engine independently requires
  # the original cached/protected SDK-entry fence before a first SDK call.
  # Primary intent publication or a generic error alone grants no SDK entry.
  defp resume(config, child, worker, budget, deadline) do
    with {:ok, stage, rest} <- reserve(budget, deadline) do
      case perform(config, child, worker, :resolve_partial_branch_disposal, stage, deadline) do
        {:error, %Error{category: :unknown, evidence: :not_dispatched}} ->
          dispatch(config, child, worker, rest, deadline)

        result ->
          result
      end
    end
  end

  defp stage(config, child, worker, operation, budget, deadline) do
    with {:ok, stage, _} <- reserve(budget, deadline),
         do: perform(config, child, worker, operation, stage, deadline)
  end

  defp perform(config, child, worker, operation, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, timeout} <- remaining(deadline) do
      budget = %{budget | timeout_ms: min(budget.timeout_ms, timeout)}
      reference = %{Target.connection(worker, parent) | budget: budget}
      io_record = %{parent | operation_deadline_ms: config.clock.now() + budget.timeout_ms}

      response =
        MachineSession.io(config, io_record, fn ->
          {:native_response, Backend.invoke(reference, operation, [parent, child])}
        end)

      case response do
        {:native_response, {:ok, %NativePartialBranchDisposalResult{} = result}} ->
          complete(config, parent, child, result, worker, deadline)

        {:native_response, {:error, %Error{} = error}} ->
          {:error, error}

        {:error, %Error{}} = error ->
          uncertain(error)

        _ ->
          uncertain(Session.error(:identity_conflict, :branch))
      end
    end
  end

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

    uncertain(completed)
  end

  defp result_bound?(result, parent, child, worker) do
    context = Target.connection(worker).context

    NativePartialBranchDisposalResult.bound?(result, parent, child) and
      get_in(result.proof.publication, ~w(change child_origin intent epoch)) == context.epoch and
      result.proof.publication["change"]["platform"] == platform(worker)
  end

  defp matching_version?(child, version) do
    saved = child.branch.native_authority.partial_disposal
    version == child.version or (saved != nil and version == saved.version)
  end

  defp reserve(budget, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         true <- budget.max_request_bytes > 0 and budget.max_response_bytes > 0,
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
    else
      false -> Session.error(:output_limit, :branch)
      error -> error
    end
  end

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
