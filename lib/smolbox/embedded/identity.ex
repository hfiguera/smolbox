defmodule SmolBox.Embedded.Identity do
  @moduledoc """
  Native machine receipt and optional running-process identity.

  The receipt identifies an owned incarnation within an enrolled data domain.
  PID/birth evidence describes a running VMM and may change on verified restart.
  Inspect output omits both kinds of evidence.
  """
  alias SmolBox.Backend.Binding

  alias SmolBox.Embedded.{
    CaptureResolutionTransition,
    CaptureTransition,
    GrowthTransition,
    MaterialHistory,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [:receipt]
  @derive {Inspect, only: []}
  defstruct [:receipt, pid_identity: nil, transition: nil, material_history: nil]

  @type t :: %__MODULE__{
          receipt: map(),
          pid_identity: [pos_integer()] | nil,
          transition: map() | nil
        }

  @doc false
  def valid?(%__MODULE__{} = identity),
    do:
      Validation.struct_shape?(identity, __MODULE__) and
        (Shape.receipt?(identity.receipt, 1) or Shape.receipt?(identity.receipt, 2)) and
        pid?(identity.pid_identity) and transition?(identity) and history?(identity)

  def valid?(_identity), do: false

  @doc false
  def matches?(
        %__MODULE__{} = identity,
        %{
          binding: %Binding{} = binding,
          creation: create
        } = assignment
      ),
      do:
        valid?(identity) and Binding.valid?(binding) and is_map(create) and
          Shape.receipt?(identity.receipt, Map.get(assignment, :version, 1)) and
          identity.receipt["target_id"] == binding.target_id and
          identity.receipt["domain_generation"] == binding.generation and
          Enum.all?(~w(name owner_token incarnation), &(identity.receipt[&1] == create[&1]))

  def matches?(_identity, _assignment), do: false

  defp transition?(%{transition: nil}), do: true

  defp transition?(%{transition: %CaptureTransition{} = transition, receipt: receipt}),
    do: CaptureTransition.valid?(transition) and transition.receipt == receipt

  defp transition?(%{transition: %CaptureResolutionTransition{} = transition, receipt: receipt}),
    do: CaptureResolutionTransition.valid?(transition) and transition.receipt == receipt

  defp transition?(%{transition: transition, receipt: receipt}),
    do: GrowthTransition.valid?(transition) and transition.receipt == receipt

  defp history?(%{material_history: nil, transition: transition}),
    do: not MaterialHistory.capture?(transition)

  defp history?(identity),
    do:
      MaterialHistory.identity?(identity.material_history, identity.receipt, identity.transition)

  defp pid?(nil), do: true

  defp pid?([pid, start]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(start, 1, 18_446_744_073_709_551_615)

  defp pid?(_pid), do: false
end
