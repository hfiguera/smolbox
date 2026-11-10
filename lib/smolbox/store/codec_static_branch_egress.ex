defmodule SmolBox.Store.CodecStaticBranchEgress do
  @moduledoc false
  alias SmolBox.{ManagedMachine, ManagedMachineSpec}

  def reader, do: 1

  def strip(%ManagedMachine{spec: %ManagedMachineSpec{branch_static_egress: false} = spec} = m),
    do: %{m | spec: Map.delete(spec, :branch_static_egress)}

  def strip(record), do: record

  def upgrade(%ManagedMachine{spec: %ManagedMachineSpec{} = spec} = m) do
    if Map.has_key?(spec, :branch_static_egress), do: raise(ArgumentError)
    %{m | spec: Map.put(spec, :branch_static_egress, false)}
  end

  def upgrade(record), do: record
end
