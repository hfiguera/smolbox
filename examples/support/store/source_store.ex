defmodule SmolBox.DurableHost.SourceStore do
  @moduledoc false

  # The community app consumes published SmolBox; the durable example consumes
  # the checkout. Compile the extension only when its enforcement is available.
  if Code.ensure_loaded?(SmolBox.Source) and Code.ensure_loaded?(SmolBox.Store.SourceOwnership) do
    alias SmolBox.DurableHost.Database
    alias SmolBox.Store.SourceOwnership

    def capabilities, do: %{registry_sources: 1, managed_images: 1}

    def available(context, record, worker) do
      if SmolBox.Source.remote?(record.spec.artifact) do
        rows =
          Database.query(
            context,
            "SELECT scope,execution_id FROM smolbox_managed_machines WHERE partition=$1 AND worker_id=$2",
            [context.partition, worker]
          ).rows

        Enum.reduce_while(rows, :ok, fn key, :ok -> source_owner(context, record, worker, key) end)
      else
        :ok
      end
    end

    defp source_owner(context, record, worker, [scope, id]) do
      with {:ok, existing} <- Database.read(context, {scope, id}, :machine),
           :ok <- SourceOwnership.available(record, worker, [existing]) do
        {:cont, :ok}
      else
        failure -> {:halt, failure}
      end
    end
  else
    def capabilities, do: %{}

    def available(_context, %{spec: %{artifact: %{"kind" => kind}}}, _worker)
        when kind in ["registry", "oci"],
        do: {:error, %SmolBox.Error{category: :validation, operation: :store}}

    def available(_context, _record, _worker), do: :ok
  end
end
