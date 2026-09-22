defmodule SmolBox.DurableHost.PortIndex do
  @moduledoc false
  alias SmolBox.DurableHost.Database
  alias SmolBox.Error

  # Called after the record write, inside the same transaction. The unique
  # worker/port key arbitrates even concurrent transactions in different store
  # partitions. A conflict rolls back every record, capacity and index change.
  def sync(context, record) do
    owner = [context.partition, record.scope, record.id]

    Database.query(
      context,
      "DELETE FROM smolbox_port_owners WHERE partition=$1 AND scope=$2 AND execution_id=$3 AND NOT (host_port=ANY($4::integer[]))",
      owner ++ [record.reserved_ports]
    )

    Enum.reduce_while(record.reserved_ports, :ok, fn port, :ok ->
      %{rows: [[partition, scope, id]]} =
        Database.query(
          context,
          """
          INSERT INTO smolbox_port_owners (worker_id,host_port,partition,scope,execution_id)
          VALUES ($1,$2,$3,$4,$5)
          ON CONFLICT (worker_id,host_port) DO UPDATE SET host_port=smolbox_port_owners.host_port
          RETURNING partition,scope,execution_id
          """,
          [record.worker_id, port | owner]
        )

      if [partition, scope, id] == owner,
        do: {:cont, :ok},
        else: {:halt, {:error, %Error{category: :port_conflict, operation: :store}}}
    end)
  end
end
