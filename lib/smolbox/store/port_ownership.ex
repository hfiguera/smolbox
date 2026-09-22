defmodule SmolBox.Store.PortOwnership do
  @moduledoc false
  alias SmolBox.{Error, ManagedMachine}

  def update(index, record) do
    owner = ManagedMachine.key(record)
    wanted = Enum.map(record.reserved_ports, &{record.worker_id, &1})

    if Enum.all?(wanted, &(Map.get(index, &1) in [nil, owner])) do
      retained = Map.reject(index, fn {key, value} -> value == owner and key not in wanted end)
      {:ok, Enum.reduce(wanted, retained, &Map.put(&2, &1, owner))}
    else
      {:error, %Error{category: :port_conflict, operation: :store}}
    end
  end
end
