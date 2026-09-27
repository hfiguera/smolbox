defmodule SmolBox.DurableHost.ExportStore do
  @moduledoc false
  # Shared with the published community example; do not advertise new contracts
  # until their codec and transaction implementation are actually loaded.
  if Code.ensure_loaded?(SmolBox.Store.ExportOps) do
    alias SmolBox.DurableHost.Database
    alias SmolBox.Store.ExportOps
    def capabilities, do: %{managed_exports: 1}

    def run(context, :export_accept, [key, spec, fingerprint, capacity, now]) do
      with {:ok, machine} <- Database.read(context, key, :machine),
           {:ok, usage} <- Database.usage(context, machine.worker_id),
           {:ok, machines} <- histories(context),
           do: ExportOps.accept(machine, spec, fingerprint, capacity, usage, machines, now)
    end

    def run(context, :export_advance, [key, guard, id, expected, changes, now]) do
      with {:ok, machine} <- Database.guarded_machine(context, key, guard, now),
           do: ExportOps.advance(machine, id, expected, changes, now)
    end

    def run(context, :export_cancel, [key, id, now]) do
      with {:ok, machine} <- Database.read(context, key, :machine),
           do: ExportOps.cancel(machine, id, now)
    end

    def run(context, :export_resolve, [key, guard, id, observed, now]) do
      with {:ok, machine} <- Database.guarded_machine(context, key, guard, now),
           do: ExportOps.resolve(machine, id, observed, now)
    end

    def run(_context, _operation, _arguments), do: invalid()

    defp histories(context) do
      rows =
        Database.query(
          context,
          "SELECT scope,execution_id FROM smolbox_managed_machines WHERE partition=$1",
          [context.partition]
        ).rows

      Enum.reduce_while(rows, {:ok, []}, fn [scope, id], {:ok, records} ->
        case Database.read(context, {scope, id}, :machine) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          error -> {:halt, error}
        end
      end)
    end
  else
    def capabilities, do: %{}
    def run(_context, _operation, _arguments), do: invalid()
  end

  defp invalid, do: {:error, %SmolBox.Error{category: :validation, operation: :export}}
end
