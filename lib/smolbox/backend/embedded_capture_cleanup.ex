defmodule SmolBox.Backend.EmbeddedCaptureCleanup do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    CaptureStagingCleanupReceipt,
    Identity,
    NativeCapture,
    NativeCaptureCleanup
  }

  alias SmolBox.{CheckpointCapture, Error}

  def run(context, capture, budget) do
    deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 30_000)

    with {:ok, previous, budget} <- prepare(context, capture, budget),
         {:ok, budget} <- remaining(budget, deadline),
         context = Call.pin(context, budget),
         {:ok, budget} <- remaining(budget, deadline),
         do:
           transfer(
             context,
             capture,
             previous,
             budget,
             fn request, reduced ->
               Call.run(context, request, reduced)
             end,
             deadline
           )
  end

  def transfer(context, capture, previous, budget, send),
    do:
      transfer(
        context,
        capture,
        previous,
        budget,
        send,
        System.monotonic_time(:millisecond) + min(budget.timeout_ms, 30_000)
      )

  def transfer(
        context,
        capture,
        previous,
        budget,
        send,
        deadline
      ) do
    with {:ok, budget} <- remaining(budget, deadline) do
      result = send.(request(capture, previous, :cleaned), budget)
      finish(context, capture, previous, result, budget, deadline, send)
    end
  end

  def prepare(context, capture, budget) do
    if EmbeddedContext.scoped?(context) and Features.supports?(context.config, :checkpoints),
      do: prepare_capture(context, capture, budget),
      else: failure(:unsupported_capability, :not_dispatched)
  end

  def prepare_capture(context, capture, budget) do
    with :ok <- CheckpointCapture.validate(capture),
         true <-
           capture.state in [:completed, :resolved_unknown] and capture.released_at_ms == nil,
         true <-
           capture.machine == {context.spec.scope, context.spec.id} and
             context.spec.checkpointable,
         true <- capture.spec.policy in context.config.checkpoint_policies,
         previous <-
           capture.native_source_receipt ||
             (capture.native_transition && capture.native_transition.previous) ||
             (context.identity && context.identity.receipt),
         true <- Identity.matches?(%Identity{receipt: previous}, context.assignment),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384),
         do: {:ok, previous, budget},
         else: (_ -> failure(:unsupported_capability, :not_dispatched))
  end

  def request(capture, previous, kind),
    do: %{
      "operation" =>
        if(kind == :aborted, do: "abort_capture_staging", else: "cleanup_capture_staging"),
      "receipt" => previous,
      "operation_id" => capture.spec.id,
      "request" => NativeCapture.request(capture),
      "quiesced" => true
    }

  defp finish(
         context,
         %{native_transition: nil, state: :resolved_unknown} = capture,
         previous,
         {:ok,
          %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"} = outcome,
          output, nil},
         budget,
         deadline,
         send
       )
       when map_size(outcome) == 3 and output == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    with {:ok, budget} <- remaining(budget, deadline) do
      result = send.(request(capture, previous, :aborted), budget)
      decode(context, capture, previous, :aborted, result)
    end
  end

  defp finish(context, capture, previous, result, _budget, _deadline, _send),
    do: decode(context, capture, previous, :cleaned, result)

  def decode(
        _context,
        capture,
        previous,
        kind,
        {:ok, %{"result" => result, "cleanup" => wire} = outcome, output, nil}
      )
      when map_size(outcome) == 2 and output == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    expected = if kind == :aborted, do: "capture_staging_aborted", else: "capture_staging_cleaned"

    with true <- result == expected,
         {:ok, receipt} <- CaptureStagingCleanupReceipt.from_wire(wire),
         proof = %NativeCaptureCleanup{kind: kind, receipt: receipt},
         true <- NativeCaptureCleanup.bound?(proof, capture, previous),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  def decode(context, capture, previous, kind, {:ok, %{"result" => "error"}, _, nil} = result),
    do: EmbeddedReply.decode(context, :cleanup_capture, request(capture, previous, kind), result)

  def decode(_context, _capture, _previous, _kind, {:error, %Error{} = error}),
    do: {:error, %{error | operation: :checkpoint}}

  def decode(_, _, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp remaining(budget, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout),
      else: failure(:expired, :dispatch_uncertain)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :checkpoint, evidence: evidence}}
end
