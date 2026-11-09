defmodule SmolBox.Backend.EmbeddedBranchSourceObservation do
  @moduledoc false
  alias SmolBox.Backend.EmbeddedBranchOperation
  alias SmolBox.Embedded.{BranchPublication, Identity}
  alias SmolBox.Error
  @frame_overhead 1024

  def finish(context, proof, {request, outcome}, {budget, call, deadline}, build) do
    with {:ok, context} <- promote(context, proof),
         {:ok, budget} <-
           EmbeddedBranchOperation.unused_budget(
             budget,
             request,
             outcome,
             deadline,
             @frame_overhead
           ),
         request = %{"operation" => "inspect", "receipt" => context.identity.receipt},
         :ok <-
           EmbeddedBranchOperation.within_budget(
             request,
             budget.max_request_bytes,
             :dispatch_uncertain,
             @frame_overhead
           ),
         response = call.(context, request, budget),
         {:ok, source} <-
           EmbeddedBranchOperation.observation(
             context,
             request,
             response,
             budget.max_response_bytes,
             @frame_overhead
           ),
         {:ok, _} <- remaining(budget, deadline),
         {:ok, result} <- build.(source),
         {:ok, _} <- remaining(budget, deadline),
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
        proof.publication["change"]["platform"] == EmbeddedBranchOperation.platform(context)

  def promote(context, proof) do
    with true <- epoch?(proof, context),
         {:ok, publication} <- BranchPublication.from_wire(proof.publication),
         do: promote_publication(context, publication),
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  def promote_publication(context, %BranchPublication{} = publication) do
    history = context.history || []

    cond do
      not BranchPublication.valid?(publication) ->
        failure(:identity_conflict, :dispatch_uncertain)

      context.identity.receipt == publication.previous ->
        history = history ++ [publication]

        identity = %Identity{
          receipt: publication.receipt,
          transition: publication,
          material_history: history
        }

        if Identity.valid?(identity),
          do: {:ok, %{context | identity: identity, history: history}},
          else: failure(:identity_conflict, :dispatch_uncertain)

      current_publication?(context, publication, history) ->
        {:ok, context}

      true ->
        failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  defp current_publication?(context, publication, history),
    do:
      context.identity.receipt == publication.receipt and
        context.identity.transition == publication and
        context.identity.material_history == history and
        List.last(history) == publication and Identity.valid?(context.identity)

  defp remaining(budget, deadline),
    do: EmbeddedBranchOperation.remaining(budget, deadline, {:branch, :not_dispatched})

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}
end
