defmodule SmolBox.Store.CodecWorkload do
  @moduledoc false
  alias SmolBox.{Error, Execution, ManagedMachine}

  def upgrade(%ManagedMachine{spec: spec} = record) do
    if Map.has_key?(spec, :workload),
      do: {:error, %Error{category: :store, operation: :codec}},
      else: {:ok, %{record | spec: Map.put(spec, :workload, nil)}}
  end

  def upgrade(%Execution{} = record), do: {:ok, record}
  def upgrade(_record), do: {:error, %Error{category: :store, operation: :codec}}

  def strip(%ManagedMachine{spec: %{workload: nil} = spec} = record),
    do: %{record | spec: Map.delete(spec, :workload)}

  def strip(record), do: record
end
