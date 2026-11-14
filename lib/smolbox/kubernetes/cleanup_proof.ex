defmodule SmolBox.Kubernetes.CleanupProof do
  @moduledoc false
  alias SmolBox.Kubernetes.{Observation, Receipt, Shape}
  alias SmolBox.Validation

  @enforce_keys [
    :receipt,
    :observed_at_ms,
    :observer_epoch,
    :api_absent,
    :terminated_processes,
    :absent_records,
    :absent_vm_directories,
    :absent_shares,
    :complete_history
  ]
  @derive {Inspect, only: [:observed_at_ms]}
  defstruct @enforce_keys ++ [version: 3]
  @type t :: %__MODULE__{}

  def valid?(%__MODULE__{receipt: %{observation: %Observation{} = capture}} = value),
    do:
      Validation.struct_shape?(value, __MODULE__) and value.version in [1, 2, 3] and
        authority?(value, capture) and value.api_absent == true and value.complete_history == true and
        absent?(value, capture)

  def valid?(_value), do: false

  # Earlier component proofs remain readable. Version 3 additionally requires
  # a persisted kubelet lifecycle witness and unchanged daemon incarnations.
  def releasable?(proof, receipt), do: matches?(proof, receipt) and proof.version == 3

  def matches?(proof, receipt),
    do: valid?(proof) and proof.receipt == receipt

  defp authority?(value, capture),
    do:
      Receipt.valid?(value.receipt) and value.receipt.phase == :ready and
        capture.complete_history == true and
        Validation.timestamp?(value.observed_at_ms) and
        value.observed_at_ms >= capture.observed_at_ms and
        value.observer_epoch == capture.observer_epoch and Shape.uid?(value.observer_epoch)

  defp absent?(value, capture),
    do:
      value.terminated_processes == capture.processes and
        value.absent_records == capture.sandbox_ids and
        value.absent_shares == capture.sandbox_ids and
        value.absent_vm_directories ==
          Enum.sort(Enum.map(capture.sandbox_ids, &Observation.vm_directory/1))
end
