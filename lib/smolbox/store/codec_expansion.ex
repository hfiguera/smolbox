defmodule SmolBox.Store.CodecExpansion do
  @moduledoc false
  alias SmolBox.{Execution, ManagedMachine}

  def required?(%ManagedMachine{disk_expansions: history}), do: history != %{}

  def required?(%Execution{managed_machine: key, created_machine: m, spec: %{profile: p}})
      when not is_nil(key) and not is_nil(m),
      do: m.storage_gb != p.storage_gb or m.overlay_gb != p.overlay_gb

  def required?(_), do: false

  def strip(%ManagedMachine{disk_expansions: h, disk_sizes: nil, active_expansion: nil} = m)
      when map_size(h) == 0,
      do: Map.drop(m, [:disk_expansions, :disk_sizes, :active_expansion])

  def strip(record), do: record

  def upgrade(%ManagedMachine{} = m) do
    if Enum.any?([:disk_expansions, :disk_sizes, :active_expansion], &Map.has_key?(m, &1)),
      do: raise(ArgumentError)

    m
    |> Map.put(:disk_expansions, %{})
    |> Map.put(:disk_sizes, nil)
    |> Map.put(:active_expansion, nil)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    record
  end
end
