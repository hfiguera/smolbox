defmodule SmolBox.Backend.EmbeddedPartialBranchDisposal do
  @moduledoc false

  alias SmolBox.Backend.{Budget, EmbeddedBranchOperation, EmbeddedBranchSourceObservation}

  alias SmolBox.Embedded.{
    NativePartialBranchCleanupCandidate,
    NativePartialBranchDisposal,
    NativePartialBranchDisposalResult,
    PartialBranchCleanupCandidate,
    PartialBranchDisposal,
    Protocol
  }

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @frame_overhead 1024
  @operations [
    :dispose_partial_branch,
    :resolve_partial_branch_disposal,
    :qualify_partial_branch_cleanup
  ]

  # Original collection precedes this control. Only the source is assigned;
  # partial-child inventory supplies no public Machine or completed creation.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <- scope?(context, operation, parent, child),
         {:ok, request} <- request(operation, child),
         :ok <-
           EmbeddedBranchOperation.within_budget(
             request,
             budget.max_request_bytes,
             :not_dispatched,
             @frame_overhead
           ),
         {:ok, transfer_budget} <- EmbeddedBranchOperation.branch_remaining(budget, deadline),
         response = call.(context, request, transfer_budget),
         {:ok, proof, outcome} <- decode(response, operation, child, budget.max_response_bytes),
         {:ok, _} <-
           EmbeddedBranchOperation.branch_remaining(budget, deadline, :dispatch_uncertain),
         do:
           finish(
             context,
             operation,
             parent,
             child,
             proof,
             {request, outcome},
             {budget, call, deadline}
           ),
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :not_dispatched)
         )
  end

  defp scope?(context, operation, parent, child),
    do:
      operation in @operations and
        EmbeddedBranchOperation.partial_scope?(context, parent, child, fn ->
          mode?(operation, child)
        end)

  defp mode?(_, child),
    do:
      match?(
        %NativePartialBranchDisposal{proof: nil, cleanup: nil},
        child.branch.native_authority.partial_disposal
      )

  defp request(operation, child),
    do:
      {:ok,
       %{
         "operation" => Atom.to_string(operation),
         "request" => child.branch.native_authority.partial_disposal.request
       }}

  defp decode(
         {:ok, %{"result" => "partial_branch_disposed", "proof" => wire} = outcome, @empty, nil},
         operation,
         child,
         maximum
       )
       when operation in @operations do
    with :ok <-
           EmbeddedBranchOperation.within_budget(
             outcome,
             maximum,
             :dispatch_uncertain,
             @frame_overhead
           ),
         true <- Protocol.valid_outcome?(outcome, 2),
         true <-
           PartialBranchDisposal.matches?(
             wire,
             child.branch.native_authority.partial_disposal.request
           ),
         {:ok, proof} <- PartialBranchDisposal.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (
           {:error, %Error{}} = error -> error
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode(
         {:ok, %{"result" => "partial_branch_cleanup_candidate", "candidate" => wire} = outcome,
          @empty, nil},
         :qualify_partial_branch_cleanup,
         child,
         maximum
       ) do
    with :ok <-
           EmbeddedBranchOperation.within_budget(
             outcome,
             maximum,
             :dispatch_uncertain,
             @frame_overhead
           ),
         true <- Protocol.valid_outcome?(outcome, 2),
         true <-
           PartialBranchCleanupCandidate.matches?(
             wire,
             child.branch.native_authority.partial_disposal.request
           ),
         {:ok, proof} <- PartialBranchCleanupCandidate.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (
           {:error, %Error{}} = error -> error
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, maximum),
    do: EmbeddedBranchOperation.error_reply(response, :branch, maximum, @frame_overhead)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}

  defp decode(_, _, _, _),
    do: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)

  defp finish(
         context,
         :qualify_partial_branch_cleanup,
         parent,
         child,
         %PartialBranchCleanupCandidate{} = proof,
         _,
         _
       ) do
    result = %NativePartialBranchCleanupCandidate{version: child.version, proof: proof}

    if NativePartialBranchCleanupCandidate.bound?(result, parent, child) and
         get_in(proof.publication, ~w(change child_origin intent epoch)) == context.epoch,
       do: {:ok, result},
       else: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
  end

  defp finish(context, _, parent, child, proof, transfer, stage) do
    EmbeddedBranchSourceObservation.finish(context, proof, transfer, stage, fn source ->
      result = %NativePartialBranchDisposalResult{
        version: child.version,
        source: source,
        proof: proof
      }

      if NativePartialBranchDisposalResult.bound?(result, parent, child),
        do: {:ok, result},
        else: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
    end)
  end

  def constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 26 * 1024,
        max_response_bytes: 64 * 1024
      )

  defp now, do: System.monotonic_time(:millisecond)
end
