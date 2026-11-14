defmodule SmolBox.Kubernetes.LabController.Context do
  @moduledoc false
  alias SmolBox.Kubernetes.Shape
  alias SmolBox.Validation
  @enforce_keys [:directory, :python_executable]
  @derive {Inspect, only: []}
  defstruct @enforce_keys ++
              [owner: nil, domain_id: nil, generation: nil, known_owners: [], enrolled: false]

  def validate(%__MODULE__{} = value) do
    if Validation.struct_shape?(value, __MODULE__) and path?(value.directory) and
         path?(value.python_executable) and authority?(value),
       do: :ok,
       else: :error
  end

  def validate(_), do: :error

  defp path?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..4096 and
        Path.type(value) == :absolute and not String.contains?(value, "\0") and
        ".." not in Path.split(value)

  defp authority?(%{owner: nil} = value),
    do:
      value.domain_id == nil and value.generation == nil and value.known_owners == [] and
        value.enrolled == false

  defp authority?(value),
    do:
      Validation.identifier?(value.owner) and Shape.uid?(value.domain_id) and
        Validation.list?(value.known_owners, 256) and value.known_owners != [] and
        Enum.all?(value.known_owners, &Validation.identifier?/1) and
        Enum.uniq(value.known_owners) == value.known_owners and
        List.last(value.known_owners) == value.owner and
        value.generation == length(value.known_owners) and
        is_boolean(value.enrolled)
end
