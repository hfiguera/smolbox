defmodule SmolBox.Embedded.NativeCaptureCleanup do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureStagingCleanupReceipt, NativeCapture, Shape}
  alias SmolBox.{CheckpointCapture, Validation}

  @enforce_keys [:kind, :receipt]
  @derive {Inspect, only: [:kind]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{kind: :cleaned | :aborted, receipt: struct()}

  def valid?(%__MODULE__{} = proof),
    do:
      Validation.struct_shape?(proof, __MODULE__) and proof.kind in [:cleaned, :aborted] and
        CaptureStagingCleanupReceipt.valid?(proof.receipt)

  def valid?(_), do: false

  def bound?(proof, %CheckpointCapture{} = capture, previous),
    do:
      valid?(proof) and Shape.receipt?(previous, 2) and
        CaptureStagingCleanupReceipt.bound?(
          proof.receipt,
          previous,
          capture.spec.id,
          NativeCapture.request(capture)
        ) and
        (proof.kind == :cleaned or
           (capture.state == :resolved_unknown and capture.native_transition == nil))

  def bound?(_, _, _), do: false
end
