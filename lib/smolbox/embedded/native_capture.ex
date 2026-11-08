defmodule SmolBox.Embedded.NativeCapture do
  @moduledoc false
  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureTransition,
    Identity,
    NativeCaptureResolution,
    NativeGrowth,
    Shape
  }

  alias SmolBox.{
    CheckpointCapture,
    DiskExpansion,
    Machine,
    ManagedMachine
  }

  defdelegate request(capture), to: CaptureTransition

  def history_valid?(m) do
    is_map(m.captures) and map_size(m.captures) <= 256 and
      Enum.all?(m.captures, fn {id, r} ->
        entry_valid?(r, id, m)
      end) and active?(m)
  end

  defp entry_valid?(r, id, m),
    do:
      CheckpointCapture.validate(r) == :ok and r.spec.id == id and
        r.machine == {m.scope, m.id} and source_result?(r, m) and source_enrolled?(r, m) and
        native_fields?(r, m) and
        (CheckpointCapture.terminal?(r) or m.active_capture == id)

  defp native_fields?(_r, %{backend_assignment: %{version: 2}}), do: true

  defp native_fields?(r, _m),
    do:
      r.native_transition == nil and r.native_source_receipt == nil and
        r.native_cleanup == nil and r.native_abort_source == nil

  defp source_enrolled?(%{native_source_receipt: nil}, _), do: true

  defp source_enrolled?(r, %{created_machine: %{backend_identity: %{receipt: origin}}} = m) do
    source = r.native_source_receipt

    receipts =
      [origin] ++
        Enum.flat_map(Map.values(m.captures) ++ Map.values(m.disk_expansions), fn
          %{native_transition: %{receipt: receipt}} -> [receipt]
          _ -> []
        end)

    Shape.receipt?(origin, 2) and Map.delete(source, "material") == Map.delete(origin, "material") and
      source in receipts
  end

  defp source_enrolled?(_, _), do: false

  defp source_result?(%{result: nil}, _), do: true

  defp source_result?(r, %{backend_assignment: %{version: 2}} = m),
    do:
      r.result.profile == NativeGrowth.capture_profile(m, r) and
        r.result.architecture == m.spec.artifact["architecture"]

  defp source_result?(%{result: result}, %{spec: spec}),
    do: result.profile == spec.profile and result.architecture == spec.artifact["architecture"]

  defp active?(%{active_capture: nil, operation: op}), do: op != :capture

  defp active?(m),
    do:
      is_struct(m.captures[m.active_capture], CheckpointCapture) and
        not CheckpointCapture.terminal?(m.captures[m.active_capture]) and m.operation == :capture and
        m.active_execution == nil and
        m.state in [:running, :unknown, :missing, :conflict]

  def source_receipt(record, capture) do
    cond do
      capture.native_source_receipt != nil -> {:ok, capture.native_source_receipt}
      capture.native_transition != nil -> {:ok, capture.native_transition.previous}
      true -> with {:ok, receipt, _, _} <- NativeGrowth.head(record), do: {:ok, receipt}
    end
  end

  def resolution_valid?(
        record,
        %{__struct__: CheckpointCapture} = capture,
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
        %{__struct__: CheckpointCapture} = capture,
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

  def observation_valid?(%{__struct__: ManagedMachine} = record, observed) do
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
