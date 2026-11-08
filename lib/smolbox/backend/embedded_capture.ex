defmodule SmolBox.Backend.EmbeddedCapture do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, Features}

  alias SmolBox.Embedded.{Call, CapturePublication, Identity}

  alias SmolBox.{CheckpointCapture, Error, ManagedMachine}

  def intent(%ManagedMachine{active_capture: id, captures: captures}) when not is_nil(id),
    do: captures[id]

  def intent(_), do: nil

  def run(context, [name, output, maximum], budget) do
    started = System.monotonic_time(:millisecond)

    with {:ok, request, budget} <- prepare(context, name, output, maximum, budget),
         context = Call.pin(context, budget),
         true <- context.server != nil and context.epoch != nil,
         remaining = started + budget.timeout_ms - System.monotonic_time(:millisecond),
         true <- remaining > 0,
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: remaining) do
      CapturePublication.receive(context.capture, request, budget, fn consumer, transfer_budget ->
        Call.run(context, request, transfer_budget, <<>>, consumer)
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, %Error{category: :expired, operation: :checkpoint, evidence: :not_dispatched}}
    end
  end

  def run(_context, _arguments, _budget),
    do: {:error, %Error{category: :validation, operation: :checkpoint}}

  def prepare(context, name, output, maximum, budget) do
    with true <- EmbeddedContext.scoped?(context),
         true <- Features.supports?(context.config, :checkpoints),
         %CheckpointCapture{state: :dispatching} = capture <- context.capture,
         :ok <- CheckpointCapture.validate(capture),
         true <- Map.get(context.spec, :checkpointable, false),
         true <- capture.machine == {context.spec.scope, context.spec.id},
         true <- capture.spec.policy in context.config.checkpoint_policies,
         true <-
           name == context.name and output == CheckpointCapture.path(capture) and
             maximum == capture.spec.policy.max_bytes,
         %Identity{} = identity <- context.identity,
         true <- Identity.valid?(identity),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: capture.spec.timeout_ms) do
      {:ok,
       %{
         "operation" => "capture_checkpoint",
         "receipt" => identity.receipt,
         "operation_id" => capture.spec.id,
         "chunk_bytes" => min(budget.max_response_bytes, 65_536),
         "request" => %{"max_bytes" => maximum, "idle" => capture.spec.idle}
       }, budget}
    else
      _ ->
        {:error,
         %Error{
           category: :unsupported_capability,
           operation: :checkpoint,
           evidence: :not_dispatched
         }}
    end
  end
end
