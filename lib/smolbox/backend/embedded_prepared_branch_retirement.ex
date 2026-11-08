defmodule SmolBox.Backend.EmbeddedPreparedBranchRetirement do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    NativeGrowth,
    NativePreparedBranchRetirement,
    NativePreparedBranchRetirementResult,
    PreparedBranchRetirement,
    Protocol
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(context, %ManagedMachine{} = parent, %ManagedMachine{} = child, budget) do
    {:ok, budget} = Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 32 * 1024)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(child.backend_assignment, context.config, child.spec),
         {:ok, pin_budget} <- remaining(budget, deadline),
         do:
           coordinate(Call.pin(context, pin_budget), parent, child, budget, &Call.run/3, deadline),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  def run(_, _, _, _), do: failure(:validation, :not_dispatched)

  # The semantic sequence is shared with inert peers without enabling admission.
  # Only original source authority is used: an uncreated child has no receipt.
  def coordinate(context, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 32 * 1024)
    deadline = deadline || now() + budget.timeout_ms

    with true <- scope?(context, parent, child),
         request = NativePreparedBranchRetirement.request(child.branch.native_authority),
         operation = %{"operation" => "retire_prepared_branch", "request" => request},
         true <- request["creation"]["source"] == context.identity.receipt,
         true <- fits?(operation, budget.max_request_bytes),
         {:ok, transfer_budget} <- remaining(budget, deadline),
         response = call.(context, operation, transfer_budget),
         {:ok, proof, outcome} <- decode(response, request, budget.max_response_bytes),
         do: observe(context, parent, child, {proof, operation, outcome}, budget, call, deadline),
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  defp scope?(context, parent, child),
    do:
      context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil and
        NativePreparedBranchRetirement.pending?(parent, child) and
        source_context?(context, parent)

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  defp observe(context, parent, child, {proof, operation, outcome}, budget, call, deadline) do
    result =
      with {:ok, budget} <- unused_budget(budget, operation, outcome, deadline),
           request = %{"operation" => "inspect", "receipt" => context.identity.receipt},
           true <- fits?(request, budget.max_request_bytes),
           response = call.(context, request, budget),
           {:ok, source} <- observation(context, request, response, budget.max_response_bytes),
           {:ok, _} <- remaining(budget, deadline),
           result = %NativePreparedBranchRetirementResult{
             version: child.version,
             source: source,
             proof: proof
           },
           true <- NativePreparedBranchRetirementResult.bound?(result, parent, child),
           do: {:ok, result},
           else: (
             {:error, _} = error -> error
             _ -> failure(:identity_conflict, :dispatch_uncertain)
           )

    uncertain(result)
  end

  defp decode(
         {:ok, %{"result" => "prepared_branch_retired", "proof" => wire} = outcome, @empty, nil},
         request,
         maximum
       ) do
    with true <- fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
         true <- PreparedBranchRetirement.matches?(wire, request),
         {:ok, proof} <- PreparedBranchRetirement.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _), do: {:error, error}
  defp decode(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp observation(context, request, {:ok, outcome, @empty, nil} = response, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(context, :inspect_machine, request, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp observation(_, _, {:error, %Error{} = error}, _), do: {:error, error}
  defp observation(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  # Aggregate JSON payloads; the Port independently bounds each framed message.
  defp unused_budget(budget, request, outcome, deadline) do
    input = budget.max_request_bytes - size(request)
    output = budget.max_response_bytes - size(outcome)

    if input > 0 and output > 0,
      do: remaining(%{budget | max_request_bytes: input, max_response_bytes: output}, deadline),
      else: failure(:output_limit, :dispatch_uncertain)
  end

  defp fits?(value, maximum), do: size(value) <= maximum
  defp size(value), do: byte_size(Jason.encode!(value))

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do:
        Budget.constrain(budget, timeout_ms: min(timeout, 30_000), max_response_bytes: 32 * 1024),
      else: failure(:expired, :not_dispatched)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | operation: :branch, evidence: :dispatch_uncertain}}

  defp uncertain(result), do: result

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
