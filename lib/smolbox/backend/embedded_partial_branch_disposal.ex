defmodule SmolBox.Backend.EmbeddedPartialBranchDisposal do
  @moduledoc false
  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedBranchSourceObservation,
    EmbeddedContext,
    EmbeddedReply,
    Features
  }

  alias SmolBox.Embedded.{
    Call,
    NativeGrowth,
    NativePartialBranchCleanupCandidate,
    NativePartialBranchDisposal,
    NativePartialBranchDisposalResult,
    PartialBranchCleanupCandidate,
    PartialBranchDisposal,
    Protocol
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @operations [
    :dispose_partial_branch,
    :resolve_partial_branch_disposal,
    :qualify_partial_branch_cleanup
  ]

  def run(context, operation, %ManagedMachine{} = parent, %ManagedMachine{} = child, budget)
      when operation in @operations do
    {:ok, budget} = constrain(budget)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(child.backend_assignment, context.config, child.spec),
         {:ok, pin_budget} <- remaining(budget, deadline),
         do:
           coordinate(
             Call.pin(context, pin_budget),
             operation,
             parent,
             child,
             budget,
             &Call.run/3,
             deadline
           ),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  def run(_, _, _, _, _), do: failure(:validation, :not_dispatched)

  # Original collection precedes this control. Only the source is assigned;
  # partial-child inventory supplies no public Machine or completed creation.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <- scope?(context, operation, parent, child),
         {:ok, request} <- request(operation, child),
         :ok <- within_budget(request, budget.max_request_bytes, :not_dispatched),
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
      operation in @operations and pinned?(context) and
        NativePartialBranchDisposal.pending?(parent, child) and
        source_context?(context, parent) and mode?(operation, child) and
        child.branch.native_authority.partial_disposal.platform == platform(context)

  defp pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

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
    with :ok <- within_budget(outcome, maximum, :dispatch_uncertain),
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
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode(
         {:ok, %{"result" => "partial_branch_cleanup_candidate", "candidate" => wire} = outcome,
          @empty, nil},
         :qualify_partial_branch_cleanup,
         child,
         maximum
       ) do
    with :ok <- within_budget(outcome, maximum, :dispatch_uncertain),
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
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, _, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

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
       else: failure(:identity_conflict, :dispatch_uncertain)
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
        else: failure(:identity_conflict, :dispatch_uncertain)
    end)
  end

  defp after_response(_operation, budget, deadline) do
    case remaining(budget, deadline) do
      {:error, %Error{} = error} ->
        {:error, %{error | evidence: :dispatch_uncertain}}

      result ->
        result
    end
  end

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 26 * 1024,
        max_response_bytes: 64 * 1024
      )

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: constrain(%{budget | timeout_ms: min(timeout, budget.timeout_ms)}),
      else: failure(:expired, :not_dispatched)
  end

  defp platform(context), do: Atom.to_string(context.config.platform)
  defp fits?(value, maximum), do: size(value) <= maximum
  defp size(value), do: byte_size(Jason.encode!(value)) + 1024

  defp within_budget(value, limit, evidence),
    do: if(fits?(value, limit), do: :ok, else: failure(:output_limit, evidence))

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
