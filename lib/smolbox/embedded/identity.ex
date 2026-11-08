defmodule SmolBox.Embedded.Identity do
  @moduledoc """
  Native machine receipt and optional running-process identity.

  The receipt identifies an owned incarnation within an enrolled data domain.
  PID/birth evidence describes a running VMM and may change on verified restart.
  Inspect output omits both kinds of evidence.
  """
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @enforce_keys [:receipt]
  @derive {Inspect, only: []}
  defstruct [:receipt, pid_identity: nil]
  @type t :: %__MODULE__{receipt: map(), pid_identity: [pos_integer()] | nil}

  @doc false
  def valid?(%__MODULE__{} = identity),
    do:
      Validation.struct_shape?(identity, __MODULE__) and Shape.receipt?(identity.receipt) and
        pid?(identity.pid_identity)

  def valid?(_identity), do: false

  @doc false
  def matches?(%__MODULE__{} = identity, %{
        binding: %Binding{} = binding,
        creation: create
      }),
      do:
        valid?(identity) and Binding.valid?(binding) and is_map(create) and
          identity.receipt["target_id"] == binding.target_id and
          identity.receipt["domain_generation"] == binding.generation and
          Enum.all?(~w(name owner_token incarnation), &(identity.receipt[&1] == create[&1]))

  def matches?(_identity, _assignment), do: false

  defp pid?(nil), do: true

  defp pid?([pid, start]),
    do:
      Validation.integer?(pid, 1, 2_147_483_647) and
        Validation.integer?(start, 1, 18_446_744_073_709_551_615)

  defp pid?(_pid), do: false
end
