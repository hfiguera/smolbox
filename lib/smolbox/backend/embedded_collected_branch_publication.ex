defmodule SmolBox.Backend.EmbeddedCollectedBranchPublication do
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
    BranchPublication,
    Call,
    NativeBranchAdmission,
    NativeCollectedBranchPublication,
    NativeCollectedBranchPublicationResult,
    NativeGrowth,
    Protocol
  }

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(context, parent, child, budget) do
    with {:ok, budget} <- constrain(budget),
         true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(child.backend_assignment, context.config, child.spec) do
      deadline = now() + budget.timeout_ms
      coordinate(Call.pin(context, budget), parent, child, budget, &Call.run/3, deadline)
    else
      {:error, _} = error -> error
      _ -> failure(:unsupported_capability, :not_dispatched)
    end
  end

  def coordinate(context, parent, child, budget, call, deadline \\ nil) do
    deadline = deadline || now() + min(budget.timeout_ms, 30_000)

    with true <- scope?(context, parent, child),
         saved = child.branch.native_authority.collected_publication,
         request = %{
           "operation" => "publish_collected_branch_material",
           "request" => saved.request["creation"],
           "quiesced" => saved.request["quiesced"]
         },
         {:ok, budget} <- constrain(budget),
         :ok <- fits(request, budget.max_request_bytes, :not_dispatched),
         {:ok, transfer} <- remaining(budget, deadline),
         response = call.(context, request, transfer),
         {:ok, proof, outcome} <- decode(response, child, budget) do
      EmbeddedBranchSourceObservation.finish(
        context,
        %{publication: BranchPublication.to_wire(proof)},
        {request, outcome},
        {budget, call, deadline},
        &build(&1, proof, parent, child, saved)
      )
    else
      {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
      _ -> failure(:identity_conflict, :not_dispatched)
    end
  end

  defp build(source, proof, parent, child, saved) do
    result = %NativeCollectedBranchPublicationResult{
      version: child.version,
      platform: saved.platform,
      source: source,
      proof: proof
    }

    if NativeCollectedBranchPublicationResult.bound?(result, parent, child),
      do: {:ok, result},
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp scope?(context, parent, child),
    do:
      pinned?(context) and NativeBranchAdmission.collected_publication_pending?(parent, child) and
        source_context?(context, parent) and pending_action?(context, child)

  defp pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  defp pending_action?(context, child),
    do:
      match?(
        %NativeCollectedBranchPublication{proof: nil},
        child.branch.native_authority.collected_publication
      ) and
        child.branch.native_authority.collected_publication.platform ==
          Atom.to_string(context.config.platform)

  defp decode(
         {:ok,
          %{"result" => "collected_branch_material_published", "publication" => wire} = outcome,
          @empty, nil},
         child,
         budget
       ) do
    with true <- Protocol.valid_outcome?(outcome, 2),
         :ok <- fits(outcome, budget.max_response_bytes, :dispatch_uncertain),
         true <- BranchPublication.matches?(wire, child.branch.native_authority.request),
         {:ok, proof} <- BranchPublication.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, budget) do
    with true <- Protocol.valid_outcome?(outcome, 2),
         :ok <- fits(outcome, budget.max_response_bytes, :dispatch_uncertain),
         do: EmbeddedReply.decode(nil, :branch, nil, response),
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:error, %Error{} = error}, _, _), do: {:error, error}
  defp decode(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 24 * 1024,
        max_response_bytes: 84 * 1024
      )

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: min(budget.timeout_ms, timeout)),
      else: failure(:expired, :not_dispatched)
  end

  defp fits(value, limit, evidence),
    do:
      if(byte_size(Jason.encode!(value)) + 1024 <= limit,
        do: :ok,
        else: failure(:output_limit, evidence)
      )

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
