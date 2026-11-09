defmodule SmolBox.Backend.EmbeddedUnbootedBranchDisposal do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedBranchOperation, EmbeddedBranchSourceObservation}

  alias SmolBox.Embedded.{
    NativeBranchAdmission,
    NativeUnbootedBranchDisposal,
    NativeUnbootedBranchDisposalResult,
    Protocol,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @operations [
    :inspect_unbooted_branch_disposal,
    :dispose_unbooted_branch,
    :resolve_unbooted_branch_disposal
  ]

  # Shared semantic sequence for the Port and inert peers. The source alone is
  # assigned: a never-booted child has no public Machine or usable child receipt.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <- scope?(context, operation, parent, child),
         {:ok, request} <- request(operation, child),
         true <- fits?(request, budget.max_request_bytes),
         {:ok, transfer_budget} <- remaining(budget, deadline),
         response = call.(context, request, transfer_budget),
         {:ok, proof, outcome} <- decode(response, operation, child, budget.max_response_bytes),
         {:ok, _} <- after_response(operation, budget, deadline),
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
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  defp scope?(context, operation, parent, child),
    do:
      operation in @operations and EmbeddedBranchOperation.pinned?(context) and
        NativeBranchAdmission.disposal_pending?(parent, child) and
        EmbeddedBranchOperation.source?(context, parent) and mode?(operation, child)

  defp mode?(:inspect_unbooted_branch_disposal, child),
    do: child.branch.native_authority.disposal == nil

  defp mode?(_, child),
    do: match?(%NativeUnbootedBranchDisposal{proof: nil}, child.branch.native_authority.disposal)

  defp request(:inspect_unbooted_branch_disposal, child),
    do:
      {:ok,
       %{
         "operation" => "inspect_unbooted_branch_disposal",
         "request" => child.branch.native_authority.request,
         "quiesced" => true
       }}

  defp request(operation, child),
    do:
      {:ok,
       %{
         "operation" => Atom.to_string(operation),
         "request" => child.branch.native_authority.disposal.request
       }}

  defp decode(
         {:ok, %{"result" => "unbooted_branch_disposal_candidate", "candidate" => wire} = outcome,
          @empty, nil},
         :inspect_unbooted_branch_disposal,
         child,
         maximum
       ) do
    with true <- fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
         true <-
           UnbootedBranchDisposalCandidate.matches?(wire, child.branch.native_authority.request),
         {:ok, proof} <- UnbootedBranchDisposalCandidate.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode(
         {:ok, %{"result" => "unbooted_branch_disposed", "proof" => wire} = outcome, @empty, nil},
         operation,
         child,
         maximum
       )
       when operation in [:dispose_unbooted_branch, :resolve_unbooted_branch_disposal] do
    with true <- fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
         true <-
           UnbootedBranchDisposal.matches?(wire, child.branch.native_authority.disposal.request),
         {:ok, proof} <- UnbootedBranchDisposal.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, maximum),
    do: EmbeddedBranchOperation.error_reply(response, :branch, maximum)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp finish(context, :inspect_unbooted_branch_disposal, parent, child, candidate, _, _) do
    if NativeBranchAdmission.disposal_candidate?(
         candidate,
         parent,
         child,
         context.epoch,
         EmbeddedBranchOperation.platform(context)
       ), do: {:ok, candidate}, else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp finish(context, _, parent, child, proof, {request, outcome}, {budget, call, deadline}) do
    with {:ok, context} <- EmbeddedBranchSourceObservation.promote(context, proof),
         {:ok, budget} <-
           EmbeddedBranchOperation.unused_budget(budget, request, outcome, deadline),
         request = %{"operation" => "inspect", "receipt" => context.identity.receipt},
         true <- fits?(request, budget.max_request_bytes),
         response = call.(context, request, budget),
         {:ok, source} <-
           EmbeddedBranchOperation.observation(
             context,
             request,
             response,
             budget.max_response_bytes
           ),
         {:ok, _} <- remaining(budget, deadline),
         result = %NativeUnbootedBranchDisposalResult{
           version: child.version,
           source: source,
           proof: proof
         },
         true <- NativeUnbootedBranchDisposalResult.bound?(result, parent, child),
         do: {:ok, result},
         else: (
           {:error, %Error{} = error} ->
             {:error, %{error | operation: :branch, evidence: :dispatch_uncertain}}

           _ ->
             failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp after_response(operation, budget, deadline) do
    case remaining(budget, deadline) do
      {:error, %Error{} = error} when operation != :inspect_unbooted_branch_disposal ->
        {:error, %{error | evidence: :dispatch_uncertain}}

      result ->
        result
    end
  end

  def constrain(budget),
    do: Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 64 * 1024)

  defp remaining(budget, deadline),
    do: EmbeddedBranchOperation.remaining(budget, deadline, {:branch, :not_dispatched})

  defp fits?(value, maximum), do: size(value) <= maximum
  defp size(value), do: byte_size(Jason.encode!(value))

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
