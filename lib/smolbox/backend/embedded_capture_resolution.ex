defmodule SmolBox.Backend.EmbeddedCaptureResolution do
  @moduledoc false
  alias SmolBox.Backend.{
    Budget,
    EmbeddedCaptureObservation,
    EmbeddedContext,
    EmbeddedOperation,
    EmbeddedReply,
    Features
  }

  alias SmolBox.Embedded.{
    Call,
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    Identity,
    NativeCapture,
    NativeCaptureResolution
  }

  alias SmolBox.{
    CheckpointCapture,
    Error
  }

  def run(context, name, budget) do
    deadline = System.monotonic_time(:millisecond) + min(budget.timeout_ms, 30_000)

    with {:ok, budget} <- prepare(context, name, budget),
         {:ok, budget} <- remaining(budget, deadline),
         context = Call.pin(context, budget),
         {:ok, promoted, qualification} <- qualify(context, budget, deadline),
         {:ok, budget} <- remaining(budget, deadline),
         {:ok, request, budget, input, callback} <-
           EmbeddedOperation.build(promoted, :inspect_machine, [name], budget),
         result = Call.run(promoted, request, budget, input, callback),
         {:ok, observed} <- EmbeddedReply.decode(promoted, :inspect_machine, request, result),
         true <- resolved_state?(promoted.identity, observed) do
      finish(observed, qualification)
    else
      {:error, %Error{} = error} -> {:error, %{error | operation: :checkpoint}}
      _ -> invalid()
    end
  end

  def prepare(context, name, budget) do
    with true <- name == context.name and EmbeddedContext.scoped?(context),
         true <- Features.supports?(context.config, :checkpoints),
         %CheckpointCapture{state: :unknown} = capture <- context.capture,
         :ok <- CheckpointCapture.validate(capture),
         true <- capture.machine == {context.spec.scope, context.spec.id},
         true <-
           context.spec.checkpointable and
             capture.spec.policy in context.config.checkpoint_policies do
      Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 16_384)
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

  def request(context),
    do:
      context
      |> EmbeddedCaptureObservation.request()
      |> Map.merge(%{"operation" => "resolve_capture", "quiesced" => true})

  defp qualify(context, budget, deadline) do
    with {:ok, budget} <- remaining(budget, deadline),
         completed = Call.run(context, EmbeddedCaptureObservation.request(context), budget),
         {:ok, promoted} <- EmbeddedCaptureObservation.promote(context, completed) do
      if promoted.identity != context.identity,
        do: {:ok, promoted, nil},
        else: qualify_entered(context, budget, deadline)
    end
  end

  defp qualify_entered(context, budget, deadline) do
    with {:ok, budget} <- remaining(budget, deadline),
         recorded =
           Call.run(context, EmbeddedCaptureObservation.resolution_request(context), budget),
         {:ok, promoted} <-
           EmbeddedCaptureObservation.promote(context, recorded, "capture_resolution_presence") do
      if promoted.identity != context.identity do
        {:ok, promoted, nil}
      else
        dispatch_resolution(context, budget, deadline)
      end
    end
  end

  defp dispatch_resolution(context, budget, deadline),
    do:
      dispatch_resolution(context, budget, deadline, fn request, reduced ->
        Call.run(context, request, reduced)
      end)

  def dispatch_resolution(context, budget, deadline, send) do
    with {:ok, budget} <- remaining(budget, deadline) do
      result = send.(Map.put(request(context), "operation", "abort_capture_staging"), budget)
      select_resolution(context, budget, deadline, send, result)
    end
  end

  defp select_resolution(
         context,
         budget,
         deadline,
         send,
         {:ok, %{"result" => "error", "code" => code, "dispatch" => "not_dispatched"} = outcome,
          empty, nil}
       )
       when code in ~w(state ownership) and map_size(outcome) == 3 and
              empty == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    with {:ok, budget} <- remaining(budget, deadline),
         {:ok, promoted} <-
           EmbeddedCaptureObservation.promote(
             context,
             send.(request(context), budget),
             "capture_resolved"
           ),
         do: {:ok, promoted, nil}
  end

  defp select_resolution(context, budget, deadline, send, result),
    do:
      qualify_aborted(context, budget, deadline, fn request, reduced ->
        if request["operation"] == "abort_capture_staging",
          do: result,
          else: send.(request, reduced)
      end)

  def qualify_aborted(context, budget, deadline, send) do
    previous = context.identity.receipt
    base = request(context)

    with {:ok, budget} <- remaining(budget, deadline),
         {:ok, %{"result" => "capture_staging_aborted", "cleanup" => cleanup} = aborted, empty,
          nil} <-
           send.(Map.put(base, "operation", "abort_capture_staging"), budget),
         true <- map_size(aborted) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>},
         {:ok, receipt} <- CaptureStagingCleanupReceipt.from_wire(cleanup),
         true <-
           CaptureStagingCleanupReceipt.bound?(
             receipt,
             previous,
             context.capture.spec.id,
             NativeCapture.request(context.capture)
           ),
         {:ok, budget} <- remaining(budget, deadline),
         {:ok,
          %{"result" => "aborted_capture_source_qualified", "qualification" => wire} = qualified,
          empty, nil} <-
           send.(Map.put(base, "operation", "qualify_aborted_capture_source"), budget),
         true <- map_size(qualified) == 2 and empty == %{stdout: <<>>, stderr: <<>>, file: <<>>},
         {:ok, proof} <- CaptureAbortSourceQualification.from_wire(wire),
         true <-
           proof.cleanup == cleanup and
             CaptureAbortSourceQualification.bound?(
               proof,
               previous,
               context.capture.spec.id,
               NativeCapture.request(context.capture)
             ) do
      {:ok, context, proof}
    else
      {:error, %Error{} = error} -> {:error, %{error | operation: :checkpoint}}
      _ -> invalid()
    end
  end

  def finish(observed, nil), do: {:ok, observed}

  def finish(observed, %CaptureAbortSourceQualification{} = proof) do
    resolution = %NativeCaptureResolution{observed: observed, qualification: proof}
    if NativeCaptureResolution.valid?(resolution), do: {:ok, resolution}, else: invalid()
  end

  def finish(_, _), do: invalid()

  defp resolved_state?(%Identity{transition: %CaptureResolutionTransition{} = proof}, observed),
    do: NativeCapture.resolution_state?(proof, observed)

  defp resolved_state?(_identity, observed), do: observed.state in [:running, :stopped]

  defp remaining(budget, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout),
      else:
        {:error,
         %Error{category: :expired, operation: :checkpoint, evidence: :dispatch_uncertain}}
  end

  defp invalid,
    do:
      {:error,
       %Error{category: :identity_conflict, operation: :checkpoint, evidence: :dispatch_uncertain}}
end
