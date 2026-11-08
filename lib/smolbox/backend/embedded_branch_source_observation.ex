defmodule SmolBox.Backend.EmbeddedBranchSourceObservation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedReply}
  alias SmolBox.Embedded.{BranchPublication, Identity, Protocol}
  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def finish(context, proof, {request, outcome}, {budget, call, deadline}, build) do
    with true <- epoch?(proof, context),
         {:ok, context} <- promote(context, proof),
         {:ok, budget} <- unused_budget(budget, request, outcome, deadline),
         request = %{"operation" => "inspect", "receipt" => context.identity.receipt},
         :ok <- within_budget(request, budget.max_request_bytes, :dispatch_uncertain),
         response = call.(context, request, budget),
         {:ok, source} <- observation(context, request, response, budget.max_response_bytes),
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
        proof.publication["change"]["platform"] == platform(context)

  defp promote(context, proof) do
    case BranchPublication.from_wire(proof.publication) do
      {:ok, publication} -> promote_publication(context, publication)
      _ -> failure(:identity_conflict, :dispatch_uncertain)
    end
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

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: min(timeout, budget.timeout_ms)),
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
