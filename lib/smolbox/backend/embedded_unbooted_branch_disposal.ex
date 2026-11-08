defmodule SmolBox.Backend.EmbeddedUnbootedBranchDisposal do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    BranchPublication,
    Call,
    Identity,
    NativeGrowth,
    NativeUnbootedBranchDisposal,
    NativeUnbootedBranchDisposalResult,
    Protocol,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @operations [
    :inspect_unbooted_branch_disposal,
    :dispose_unbooted_branch,
    :resolve_unbooted_branch_disposal
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
      operation in @operations and pinned?(context) and
        NativeUnbootedBranchDisposal.pending?(parent, child) and
        source_context?(context, parent) and mode?(operation, child)

  defp pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

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

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, _, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp finish(context, :inspect_unbooted_branch_disposal, parent, child, candidate, _, _) do
    if UnbootedBranchDisposalCandidate.bound?(
         candidate,
         parent,
         child,
         context.epoch,
         platform(context)
       ), do: {:ok, candidate}, else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp finish(context, _, parent, child, proof, {request, outcome}, {budget, call, deadline}) do
    with true <- epoch?(proof, context),
         {:ok, context} <- promote(context, proof),
         {:ok, budget} <- unused_budget(budget, request, outcome, deadline),
         request = %{"operation" => "inspect", "receipt" => context.identity.receipt},
         true <- fits?(request, budget.max_request_bytes),
         response = call.(context, request, budget),
         {:ok, source} <- observation(context, request, response, budget.max_response_bytes),
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

  defp epoch?(proof, context),
    do:
      get_in(proof.publication, ~w(change child_origin intent epoch)) == context.epoch and
        proof.publication["change"]["platform"] == platform(context)

  defp promote(context, proof) do
    with true <- proof.publication["previous"] == context.identity.receipt,
         {:ok, publication} <- BranchPublication.from_wire(proof.publication),
         history = (context.history || []) ++ [publication],
         identity = %Identity{
           receipt: publication.receipt,
           transition: publication,
           material_history: history
         },
         true <- Identity.valid?(identity),
         do: {:ok, %{context | identity: identity, history: history}},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp observation(context, request, {:ok, outcome, @empty, nil} = response, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(context, :inspect_machine, request, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp observation(_, _, {:error, %Error{} = error}, _), do: {:error, error}
  defp observation(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp unused_budget(budget, request, outcome, deadline) do
    input = budget.max_request_bytes - size(request)
    output = budget.max_response_bytes - size(outcome)

    if input > 0 and output > 0,
      do: remaining(%{budget | max_request_bytes: input, max_response_bytes: output}, deadline),
      else: failure(:output_limit, :dispatch_uncertain)
  end

  defp after_response(operation, budget, deadline) do
    case remaining(budget, deadline) do
      {:error, %Error{} = error} when operation != :inspect_unbooted_branch_disposal ->
        {:error, %{error | evidence: :dispatch_uncertain}}

      result ->
        result
    end
  end

  defp constrain(budget),
    do: Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 64 * 1024)

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: constrain(%{budget | timeout_ms: min(timeout, budget.timeout_ms)}),
      else: failure(:expired, :not_dispatched)
  end

  defp platform(context), do: Atom.to_string(context.config.platform)
  defp fits?(value, maximum), do: size(value) <= maximum
  defp size(value), do: byte_size(Jason.encode!(value))

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
