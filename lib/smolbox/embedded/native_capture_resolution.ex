defmodule SmolBox.Embedded.NativeCaptureResolution do
  @moduledoc false
  alias SmolBox.Embedded.{CaptureAbortSourceQualification, Identity}
  alias SmolBox.{Machine, Validation}

  @enforce_keys [:observed, :qualification]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  def valid?(
        %__MODULE__{observed: %Machine{backend_identity: %Identity{} = identity} = observed} =
          resolution
      ),
      do:
        Validation.struct_shape?(resolution, __MODULE__) and
          CaptureAbortSourceQualification.valid?(resolution.qualification) and
          Identity.valid?(identity) and
          identity.receipt == resolution.qualification.cleanup["previous"] and
          state?(resolution.qualification, observed)

  def valid?(_), do: false

  defp state?(%{state: "running", intent: intent}, %{
         state: :running,
         backend_identity: %{pid_identity: pid}
       }),
       do: pid == intent["source_pid"]

  defp state?(%{state: "stopped"}, %{state: :stopped, backend_identity: %{pid_identity: nil}}),
    do: true

  defp state?(_, _), do: false
end
