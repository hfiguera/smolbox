defmodule SmolBox.Store.CodecExports do
  @moduledoc false
  alias SmolBox.ManagedMachine
  def required?(%ManagedMachine{exports: exports}), do: exports != %{}
  def required?(_record), do: false

  def strip(%ManagedMachine{exports: exports, active_export: nil} = record)
      when map_size(exports) == 0,
      do: Map.drop(record, [:exports, :active_export])

  def strip(record), do: record

  def upgrade(%ManagedMachine{} = record) do
    if Map.has_key?(record, :exports) or Map.has_key?(record, :active_export),
      do: raise(ArgumentError)

    record |> Map.put(:exports, %{}) |> Map.put(:active_export, nil)
  end

  def upgrade(record), do: record
end
