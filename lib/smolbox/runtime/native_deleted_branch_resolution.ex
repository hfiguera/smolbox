defmodule SmolBox.Runtime.NativeDeletedBranchResolution do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Backend.Budget

  alias SmolBox.Embedded.{
    NativeUnbootedBranchDisposal,
    NativeUnbootedBranchDisposalResult,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  alias SmolBox.Runtime.{
    MachineSession,
    NativePreparedBranchRetirement,
    NativeResolution,
    Session,
    Target
  }

  def run(
        _config,
        _coordinator,
        %{branch: %{native_authority: %{disposal: %{proof: %UnbootedBranchDisposal{}}}}} = child
      ) do
    if ManagedMachine.validate(child) == :ok,
      do: {:ok, child},
      else: Session.error(:identity_conflict, :branch)
  end

  def run(config, coordinator, %{branch: %{native_authority: %{disposal: nil}}} = child),
    do:
      NativePreparedBranchRetirement.run(config, coordinator, child, fn parent,
                                                                        child,
                                                                        worker,
                                                                        deadline,
                                                                        error ->
        select(config, parent, child, worker, deadline, error)
      end)

  def run(config, coordinator, child) do
    with :ok <- ManagedMachine.validate(child),
         true <- NativeUnbootedBranchDisposal.eligible?(child),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- require_operations(worker) do
      budget = Target.connection(worker).budget
      deadline = now() + min(budget.timeout_ms, 30_000)

      NativeResolution.run(config, coordinator, parent, worker, :deleted, fn pinned ->
        uncertain(resume(config, parent, child, pinned, budget, deadline))
      end)
    else
      false -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  # A retirement error is never evidence of SDK entry. Obtain a positive candidate
  # under the SAME controller/helper fence before saving any disposal intent.
  defp select(config, parent, child, worker, deadline, original_error) do
    with :ok <- require_operations(worker),
         :ok <- Target.require_operation(worker, :inspect_unbooted_branch_disposal) do
      with {:ok, budget} <- after_prepared(Target.connection(worker).budget),
           {:ok, stage, budget} <- reserve(budget, 20 * 1024, 34 * 1024, deadline),
           {:ok, %UnbootedBranchDisposalCandidate{} = candidate} <-
             perform(config, parent, child, worker, :inspect_unbooted_branch_disposal, stage),
           true <- candidate_bound?(candidate, parent, child, worker),
           {:ok, _} <- remaining(deadline),
           {:ok, current} <- MachineSession.claim(config, child.branch.source),
           true <- candidate_bound?(candidate, current, child, worker),
           {:ok, _} <- remaining(deadline),
           {:ok, accepted} <-
             MachineSession.store(config, :branch_advance, [
               child.branch.source,
               Session.guard(current),
               child.id,
               child.branch.state,
               {:accept_unbooted_disposal, child.version},
               config.clock.now()
             ]),
           do: uncertain(dispatch(config, accepted, worker, budget, deadline)),
           else: (
             {:error, _} = error -> error
             _ -> Session.error(:identity_conflict, :branch)
           )
    else
      _ -> original_error
    end
  end

  defp dispatch(config, child, worker, budget, deadline) do
    with {:ok, _} <- remaining(deadline),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, stage, _} <- reserve(budget, 20 * 1024, 64 * 1024, deadline),
         {:ok, result} <- perform(config, parent, child, worker, :dispose_unbooted_branch, stage),
         true <- result_bound?(result, parent, child, worker),
         do: commit(config, child, result, deadline),
         else: (
           {:error, _} = error -> error
           _ -> Session.error(:identity_conflict, :branch)
         )
  end

  # An accepted request is immutable across claims and retries. First observe its
  # original ledger without selecting another job or replaying SDK deletion. If
  # no result is available, the SAME request may be offered to one-shot dispatch;
  # the native original-context grant refuses entered SDK work independently.
  defp resume(config, parent, child, worker, budget, deadline) do
    with {:ok, stage, budget} <- reserve(budget, 20 * 1024, 64 * 1024, deadline) do
      case perform(config, parent, child, worker, :resolve_unbooted_branch_disposal, stage) do
        {:ok, result} ->
          complete(config, parent, child, result, worker, deadline)

        {:error, _} ->
          dispatch(config, child, worker, budget, deadline)
      end
    end
  end

  defp perform(config, parent, child, worker, operation, budget) do
    reference = %{Target.connection(worker, parent) | budget: budget}
    io_record = %{parent | operation_deadline_ms: config.clock.now() + budget.timeout_ms}

    case MachineSession.io(config, io_record, fn ->
           {:native_response, Backend.invoke(reference, operation, [parent, child])}
         end) do
      {:native_response, {:ok, result}} -> {:ok, result}
      {:native_response, {:error, %Error{}} = error} -> error
      {:error, %Error{}} = error -> uncertain(error)
      _ -> uncertain(Session.error(:unknown, :branch))
    end
  end

  defp complete(config, parent, child, result, worker, deadline) do
    if result_bound?(result, parent, child, worker),
      do: commit(config, child, result, deadline),
      else: Session.error(:identity_conflict, :branch)
  end

  defp commit(config, child, result, deadline) do
    with {:ok, _} <- remaining(deadline),
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
           ])
  end

  defp candidate_bound?(candidate, parent, child, worker) do
    context = Target.connection(worker).context

    UnbootedBranchDisposalCandidate.bound?(
      candidate,
      parent,
      child,
      context.epoch,
      Atom.to_string(context.config.platform)
    )
  end

  defp result_bound?(%NativeUnbootedBranchDisposalResult{} = result, parent, child, worker) do
    context = Target.connection(worker).context

    NativeUnbootedBranchDisposalResult.bound?(result, parent, child) and
      get_in(result.proof.publication, ~w(change child_origin intent epoch)) == context.epoch and
      result.proof.publication["change"]["platform"] == Atom.to_string(context.config.platform)
  end

  defp result_bound?(_, _, _, _), do: false

  defp require_operations(worker) do
    with :ok <- Target.require_operation(worker, :dispose_unbooted_branch),
         do: Target.require_operation(worker, :resolve_unbooted_branch_disposal)
  end

  # Charge offered upper bounds, including failed/lost replies, across the whole
  # public call. No backend stage can regain another stage's transfer allowance.
  defp after_prepared(budget) do
    input = budget.max_request_bytes - min(budget.max_request_bytes, 32 * 1024)
    output = budget.max_response_bytes - min(budget.max_response_bytes, 32 * 1024)

    if input > 0 and output > 0,
      do: {:ok, %{budget | max_request_bytes: input, max_response_bytes: output}},
      else: Session.error(:output_limit, :branch)
  end

  defp reserve(budget, input, output, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         true <- budget.max_request_bytes > 0 and budget.max_response_bytes > 0,
         {:ok, stage} <-
           Budget.constrain(budget,
             timeout_ms: timeout,
             max_request_bytes: input,
             max_response_bytes: output
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
    if timeout > 0, do: {:ok, min(timeout, 30_000)}, else: Session.error(:expired, :branch)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | operation: :branch, evidence: :dispatch_uncertain}}

  defp uncertain(result), do: result
  defp now, do: System.monotonic_time(:millisecond)
end
