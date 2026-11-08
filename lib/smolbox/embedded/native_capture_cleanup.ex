defmodule SmolBox.Embedded.NativeCaptureCleanup do
  @moduledoc """
  Correlated native checkpoint staging cleanup or abort evidence for store adapters.

  Bind the receipt to the saved source, capture ID and request before changing
  staging accounting. Cleanup and pre-entry abort are distinct from a completed
  capture or successful source resolution. Preserve material and artifact charges
  according to the capture transaction contract. Inspect output omits the receipt;
  this type cannot enroll a native manager or enable capture admission.
  """
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
