defmodule SmolBox.Backend.EmbeddedGrowthObservation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedOperation, EmbeddedReply, Features}
  alias SmolBox.Embedded.{Call, GrowthTransition, Identity}
  alias SmolBox.Error

  # A completed journal link can restore observation authority, never mutation
  # authority. The durable unknown intent and its reservation remain unchanged.
  def run(context, name, budget) do
    deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 30_000)

    with true <- name == context.name and EmbeddedContext.scoped?(context),
         true <- Features.supports?(context.config, :disk_growth),
         {:ok, budget} <- Budget.constrain(budget, max_response_bytes: 16_384),
         {:ok, pin_budget} <- Budget.until(budget, deadline, :inspect),
         context = Call.pin(context, pin_budget),
         {:ok, lookup_budget} <- Budget.until(budget, deadline, :inspect),
         result = Call.run(context, request(context), lookup_budget),
         {:ok, observed_context} <- promote(context, result),
         {:ok, inspect_budget} <- Budget.until(budget, deadline, :inspect),
         {:ok, request, inspect_budget, input, callback} <-
           EmbeddedOperation.build(observed_context, :inspect_machine, [name], inspect_budget) do
      observed_context
      |> Call.run(request, inspect_budget, input, callback)
      |> then(&EmbeddedReply.decode(observed_context, :inspect_machine, request, &1))
    else
      {:error, _error} = error -> error
      _invalid -> invalid()
    end
  end

  def request(%{growth: growth}),
    do: %{
      "operation" => "inspect_growth",
      "receipt" => growth.receipt,
      "operation_id" => growth.id,
      "request" => growth.request,
      "previous" => growth.previous
    }

  def promote(
        %{growth: %{state: state} = growth} = context,
        {:ok, %{"result" => "growth_presence", "transition" => wire} = outcome, empty, nil}
      )
      when state in [:dispatching, :unknown] and
             empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} and map_size(outcome) == 2 do
    if wire == nil do
      # The old receipt may still observe verified absence for explicit deleted
      # resolution. Old geometry cannot satisfy the existing target/proof gate.
      {:ok, context}
    else
      with {:ok, proof} <- GrowthTransition.from_wire(wire),
           true <- context.identity.receipt == growth.receipt,
           true <-
             GrowthTransition.bound?(
               proof,
               growth.receipt,
               growth.id,
               growth.request,
               growth.previous,
               growth.targets
             ) do
        {:ok,
         %{context | identity: %Identity{receipt: proof.receipt, transition: proof}, growth: nil}}
      else
        _invalid -> invalid()
      end
    end
  end

  def promote(_context, {:error, %Error{} = error}),
    do: {:error, %{error | operation: :inspect}}

  def promote(_context, _result), do: invalid()

  defp invalid,
    do:
      {:error,
       %Error{category: :identity_conflict, operation: :inspect, evidence: :dispatch_uncertain}}
end
