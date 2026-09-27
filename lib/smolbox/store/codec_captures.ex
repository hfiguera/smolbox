defmodule SmolBox.Store.CodecCaptures do
  @moduledoc false
  alias SmolBox.ManagedMachine

  def required?(%ManagedMachine{spec: %{checkpointable: enabled}, captures: history}),
    do: enabled or history != %{}

  def required?(_), do: false

  def strip(
        %ManagedMachine{
          spec: %{checkpointable: false} = spec,
          captures: captures,
          active_capture: nil
        } = record
      )
      when map_size(captures) == 0,
      do:
        record
        |> Map.put(:spec, Map.delete(spec, :checkpointable))
        |> Map.drop([:captures, :active_capture])

  def strip(record), do: record

  def upgrade(%ManagedMachine{spec: spec} = record) do
    if Map.has_key?(spec, :checkpointable) or Map.has_key?(record, :captures) or
         Map.has_key?(record, :active_capture),
       do: raise(ArgumentError)

    record
    |> Map.put(:spec, Map.put(spec, :checkpointable, false))
    |> Map.put(:captures, %{})
    |> Map.put(:active_capture, nil)
  end

  def upgrade(record), do: record
end
