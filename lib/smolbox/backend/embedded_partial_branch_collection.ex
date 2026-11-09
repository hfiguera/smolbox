defmodule SmolBox.Backend.EmbeddedPartialBranchCollection do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    NativeBranchAdmission,
    NativeGrowth,
    NativePartialBranchCollectionResult,
    PartialBranchCollection,
    Protocol
  }

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  def run(context, parent, child, budget) do
    with {:ok, budget} <- constrain(budget),
         true <-
           EmbeddedContext.scoped?(context) and
             Features.supports?(context.config, :branches) and context.quiesced do
      deadline = now() + budget.timeout_ms
      coordinate(Call.pin(context, budget), parent, child, budget, &Call.run/3, deadline)
    else
      {:error, _} = error -> error
      _ -> failure(:unsupported_capability, :not_dispatched)
    end
  end

  def coordinate(context, parent, child, budget, call, deadline \\ nil) do
    deadline = deadline || now() + min(budget.timeout_ms, 30_000)

    with true <-
           context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil,
         true <- NativeBranchAdmission.partial_collection_pending?(parent, child),
         true <- context.spec == parent.spec and context.assignment == parent.backend_assignment,
         true <- NativeGrowth.current_identity(parent) == {:ok, context.identity},
         saved when not is_nil(saved) <- child.branch.native_authority.partial_collection,
         true <- saved.proof == nil and saved.platform == Atom.to_string(context.config.platform),
         {:ok, budget} <- constrain(budget),
         request = %{"operation" => "collect_partial_branch", "request" => saved.request},
         :ok <- within_budget(request, budget.max_request_bytes, :not_dispatched),
         {:ok, budget} <- remaining(budget, deadline, :not_dispatched),
         response = call.(context, request, budget),
         {:ok, _} <- remaining(budget, deadline, :dispatch_uncertain),
         {:ok, result} <- decode(response, child, budget),
         {:ok, _} <- remaining(budget, deadline, :dispatch_uncertain),
         do: {:ok, result},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  defp decode(
         {:ok,
          %{"result" => "partial_branch_collected", "proof" => wire, "platform" => platform} =
            outcome, @empty, nil},
         child,
         budget
       ) do
    with true <- Protocol.valid_outcome?(outcome, 2),
         :ok <- within_budget(outcome, budget.max_response_bytes, :dispatch_uncertain),
         {:ok, proof} <- PartialBranchCollection.from_wire(wire),
         result = %NativePartialBranchCollectionResult{
           version: child.version,
           proof: proof,
           platform: platform
         },
         true <- NativePartialBranchCollectionResult.bound?(result, child),
         do: {:ok, result},
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, budget) do
    with true <- Protocol.valid_outcome?(outcome, 2),
         :ok <- within_budget(outcome, budget.max_response_bytes, :dispatch_uncertain),
         do: EmbeddedReply.decode(nil, :branch, nil, response),
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:error, %Error{} = error}, _, _), do: {:error, error}
  defp decode(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp within_budget(value, limit, evidence),
    do:
      if(byte_size(Jason.encode!(value)) + 1024 <= limit,
        do: :ok,
        else: failure(:output_limit, evidence)
      )

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 21 * 1024,
        max_response_bytes: 6 * 1024
      )

  defp remaining(budget, deadline, evidence) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout),
      else: failure(:expired, evidence)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, evidence: evidence, operation: :branch}}

  defp now, do: System.monotonic_time(:millisecond)
end
