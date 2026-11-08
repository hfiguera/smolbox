defmodule SmolBox.Backend.EmbeddedCaptureObservation do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedOperation, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    CaptureResolutionTransition,
    CaptureTransition,
    Identity,
    NativeCapture
  }

  alias SmolBox.Error

  def run(context, name, budget) do
    deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 30_000)

    with true <- name == context.name and EmbeddedContext.scoped?(context),
         true <- Features.supports?(context.config, :checkpoints),
         {:ok, budget} <- Budget.constrain(budget, max_response_bytes: 16_384) do
      observe(context, name, budget, deadline)
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  def observe(context, name, budget, deadline) do
    with {:ok, pin_budget} <- Budget.until(budget, deadline, :inspect),
         context = Call.pin(context, pin_budget),
         {:ok, lookup_budget} <- Budget.until(budget, deadline, :inspect),
         result = Call.run(context, request(context), lookup_budget),
         {:ok, promoted} <- recover(context, result, lookup_budget, deadline),
         {:ok, inspect_budget} <- Budget.until(budget, deadline, :inspect),
         {:ok, request, inspect_budget, input, callback} <-
           EmbeddedOperation.build(promoted, :inspect_machine, [name], inspect_budget) do
      promoted
      |> Call.run(request, inspect_budget, input, callback)
      |> then(&EmbeddedReply.decode(promoted, :inspect_machine, request, &1))
    else
      {:error, _} = error -> error
      _ -> invalid()
    end
  end

  def request(%{capture: capture, identity: identity}),
    do: %{
      "operation" => "inspect_capture",
      "receipt" => identity.receipt,
      "operation_id" => capture.spec.id,
      "request" => NativeCapture.request(capture)
    }

  def resolution_request(context),
    do: Map.put(request(context), "operation", "inspect_capture_resolution")

  defp recover(
         context,
         {:ok, %{"result" => "capture_presence", "transition" => nil} = outcome, empty, nil} =
           result,
         budget,
         deadline
       )
       when map_size(outcome) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    with {:ok, ^context} <- promote(context, result),
         {:ok, budget} <- Budget.until(budget, deadline, :inspect),
         do:
           promote(
             context,
             Call.run(context, resolution_request(context), budget),
             "capture_resolution_presence"
           )
  end

  defp recover(context, result, _budget, _deadline), do: promote(context, result)

  # Observation alone cannot persist recovered authority or adopt local output.
  def promote(context, result, expected \\ "capture_presence")

  def promote(
        %{capture: %{state: state} = capture} = context,
        {:ok, %{"result" => kind, "transition" => wire} = outcome, empty, nil},
        expected
      )
      when state in [:dispatching, :unknown] and map_size(outcome) == 2 and
             empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} and
             kind in ~w(capture_presence capture_resolution_presence capture_resolved) do
    if kind != expected do
      invalid()
    else
      promote_wire(context, capture, kind, wire)
    end
  end

  def promote(context, {:ok, %{"result" => "error"}, _output, nil} = result, _expected),
    do: EmbeddedReply.decode(context, :inspect_machine, request(context), result)

  def promote(_context, {:error, %Error{} = error}, _expected),
    do: {:error, %{error | operation: :inspect}}

  def promote(_context, _result, _expected), do: invalid()

  defp promote_wire(context, capture, kind, wire) do
    if wire == nil do
      if kind == "capture_resolved", do: invalid(), else: {:ok, context}
    else
      type =
        if kind == "capture_presence", do: CaptureTransition, else: CaptureResolutionTransition

      with {:ok, proof} <- type.from_wire(wire),
           true <-
             type.bound?(
               proof,
               context.identity.receipt,
               capture.spec.id,
               NativeCapture.request(capture)
             ) do
        history =
          (context.history || context.identity.material_history || prior_growth(context.identity)) ++
            [proof]

        promote_identity(context, %Identity{
          receipt: proof.receipt,
          transition: proof,
          material_history: history
        })
      else
        _ -> invalid()
      end
    end
  end

  defp promote_identity(context, identity) do
    if Identity.valid?(identity), do: {:ok, %{context | identity: identity}}, else: invalid()
  end

  # Before any capture, growth-only identities hold only the last link. Scoped
  # capture/growth combinations remain excluded from public admission.
  defp prior_growth(%{transition: nil}), do: []
  defp prior_growth(%{transition: transition}), do: [transition]

  defp invalid,
    do:
      {:error,
       %Error{category: :identity_conflict, operation: :inspect, evidence: :dispatch_uncertain}}
end
