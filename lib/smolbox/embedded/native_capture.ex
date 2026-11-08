defmodule SmolBox.Embedded.NativeCapture do
  @moduledoc false
  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureTransition,
    Identity,
    NativeCaptureResolution,
    NativeGrowth
  }

  alias SmolBox.{
    CheckpointCapture,
    DiskExpansion,
    Machine,
    ManagedMachine
  }

  def request(capture),
    do: %{"max_bytes" => capture.spec.policy.max_bytes, "idle" => capture.spec.idle}

  def source_receipt(record, capture) do
    cond do
      capture.native_source_receipt != nil -> {:ok, capture.native_source_receipt}
      capture.native_transition != nil -> {:ok, capture.native_transition.previous}
      true -> with {:ok, receipt, _, _} <- NativeGrowth.head(record), do: {:ok, receipt}
    end
  end

  def resolution_valid?(
        record,
        %CheckpointCapture{} = capture,
        %NativeCaptureResolution{} = resolution
      ) do
    observed = resolution.observed

    with true <- match?(%{backend_assignment: %{version: 2}}, record),
         true <- capture.state == :unknown and CheckpointCapture.validate(capture) == :ok,
         true <-
           record.active_capture == capture.spec.id and NativeCaptureResolution.valid?(resolution),
         {:ok, receipt, _, _} <- NativeGrowth.head(record),
         true <- capture.native_source_receipt == receipt,
         true <-
           CaptureAbortSourceQualification.bound?(
             resolution.qualification,
             receipt,
             capture.spec.id,
             request(capture)
           ),
         %Machine{} = expected <- DiskExpansion.expected(record),
         true <- observed.backend_identity.transition == expected.backend_identity.transition,
         true <-
           observed.backend_identity.material_history ==
             expected.backend_identity.material_history do
      Machine.same_incarnation?(expected, observed)
    else
      _ -> false
    end
  end

  def resolution_valid?(
        record,
        %CheckpointCapture{} = capture,
        %Machine{backend_identity: %Identity{} = identity} = observed
      ) do
    with true <- match?(%{backend_assignment: %{version: 2}}, record),
         true <-
           capture.state in [:dispatching, :unknown] and
             CheckpointCapture.validate(capture) == :ok,
         true <- record.active_capture == capture.spec.id,
         true <- observed.state in [:running, :stopped] and Identity.valid?(identity),
         proof <- identity.transition,
         {:ok, receipt, _sizes, _last} <- NativeGrowth.head(record),
         true <- resolution_proof?(proof, receipt, capture, observed),
         {:ok, history} <- NativeGrowth.transitions(record),
         true <- identity.material_history == history ++ [proof],
         %Machine{} = expected <- DiskExpansion.expected(record) do
      Machine.same_incarnation?(%{expected | backend_identity: identity}, observed)
    else
      _ -> false
    end
  end

  def resolution_valid?(_record, _capture, _observed), do: false

  defp resolution_proof?(%CaptureTransition{} = proof, receipt, capture, _observed),
    do: CaptureTransition.bound?(proof, receipt, capture.spec.id, request(capture))

  defp resolution_proof?(%CaptureResolutionTransition{} = proof, receipt, capture, observed),
    do:
      resolution_state?(proof, observed) and
        CaptureResolutionTransition.bound?(proof, receipt, capture.spec.id, request(capture))

  defp resolution_proof?(_, _, _, _), do: false

  def resolution_state?(proof, %{state: :stopped, backend_identity: %{pid_identity: nil}}),
    do: CaptureResolutionTransition.valid?(proof)

  def resolution_state?(proof, %{state: :running, backend_identity: %{pid_identity: pid}}),
    do: CaptureResolutionTransition.valid?(proof) and pid == proof.change["intent"]["source_pid"]

  def resolution_state?(_, _), do: false

  def observation_valid?(%ManagedMachine{} = record, observed) do
    DiskExpansion.matches?(record, observed) or
      resolution_valid?(
        record,
        Map.get(record, :captures, %{})[Map.get(record, :active_capture)],
        observed
      )
  end

  def observation_valid?(%{created_machine: %Machine{} = expected}, observed),
    do: Machine.same_incarnation?(expected, observed)

  def observation_valid?(_record, _observed), do: false
end
