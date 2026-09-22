defmodule SmolBox.Store.CodecPorts do
  @moduledoc false
  alias SmolBox.{Error, Execution, Machine, ManagedMachine, ManagedMachineSpec}

  # Prior schemas cannot carry port fields, even empty or forged ones. Add only
  # the documented defaults after checking their absence, then validate normally.
  def upgrade(%ManagedMachine{spec: %ManagedMachineSpec{} = spec} = record) do
    with false <- Map.has_key?(record, :reserved_ports),
         false <- Map.has_key?(spec, :ports),
         {:ok, created} <- observation(record.created_machine),
         {:ok, observed} <- observation(record.observed_machine) do
      {:ok,
       record
       |> Map.put(:reserved_ports, [])
       |> Map.put(:spec, Map.put(spec, :ports, []))
       |> Map.put(:created_machine, created)
       |> Map.put(:observed_machine, observed)}
    else
      _invalid -> invalid()
    end
  end

  def upgrade(%Execution{} = record) do
    with {:ok, created} <- observation(record.created_machine),
         do: {:ok, %{record | created_machine: created}}
  end

  def upgrade(_record), do: invalid()

  def strip(%Execution{created_machine: machine} = record),
    do: %{record | created_machine: if(machine, do: Map.delete(machine, :ports))}

  defp observation(nil), do: {:ok, nil}

  defp observation(%Machine{} = machine) do
    if Map.has_key?(machine, :ports),
      do: invalid(),
      else: {:ok, Map.put(machine, :ports, [])}
  end

  defp observation(_machine), do: invalid()
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
