defmodule SmolBox.DurableHost.WorkerStore do
  @moduledoc false

  if Code.ensure_loaded?(SmolBox.WorkerControl) do
    alias SmolBox.DurableHost.Database
    alias SmolBox.{Error, Validation, WorkerControl, WorkerMaintenance}

    def capabilities(context) do
      Database.query(
        context,
        "SELECT worker_id,mode,version,request_version,updated_at_ms FROM smolbox_worker_controls LIMIT 0",
        []
      )

      Map.merge(
        %{worker_control: 1},
        if(Code.ensure_loaded?(SmolBox.DiskExpansion),
          do: %{managed_disk_expansion: 1},
          else: %{}
        )
      )
    end

    # Callers hold the partition lock for changes, admission gates and reports.
    def read(context, worker) do
      if Validation.identifier?(worker) do
        rows =
          Database.query(
            context,
            "SELECT mode,version,request_version,updated_at_ms FROM smolbox_worker_controls WHERE partition=$1 AND worker_id=$2",
            [context.partition, worker]
          ).rows

        decode(worker, rows)
      else
        error(:validation)
      end
    end

    defp decode(worker, []), do: {:ok, WorkerControl.initial(worker)}

    defp decode(worker, [[mode, version, request, now]]) when mode in ["active", "draining"] do
      control = %WorkerControl{
        worker_id: worker,
        mode: if(mode == "active", do: :active, else: :draining),
        version: version,
        request_version: request,
        updated_at_ms: now
      }

      if WorkerControl.validate(control) == :ok, do: {:ok, control}, else: error(:store)
    end

    defp decode(_, _), do: error(:store)

    def change(context, worker, mode, expected, now) do
      with {:ok, current} <- read(context, worker),
           {:ok, next} <- WorkerControl.change(current, mode, expected, now) do
        Database.query(
          context,
          """
          INSERT INTO smolbox_worker_controls (partition,worker_id,mode,version,request_version,updated_at_ms)
          VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (partition,worker_id) DO UPDATE SET
            mode=EXCLUDED.mode,version=EXCLUDED.version,request_version=EXCLUDED.request_version,updated_at_ms=EXCLUDED.updated_at_ms
          """,
          [
            context.partition,
            worker,
            Atom.to_string(next.mode),
            next.version,
            next.request_version,
            next.updated_at_ms
          ]
        )

        {:ok, next}
      end
    end

    def admit(context, worker) do
      with {:ok, control} <- read(context, worker), do: WorkerControl.admit(control)
    end

    def admit_change(_context, record, record), do: :ok
    def admit_change(context, before, _after), do: admit(context, before.worker_id)

    def maintenance(context, worker, cursor, limit, now) do
      if WorkerMaintenance.valid_page?(worker, cursor, limit) and Validation.timestamp?(now) do
        with {:ok, control} <- read(context, worker),
             {:ok, usage} <- Database.usage(context, worker),
             {:ok, records} <- Database.worker_records(context, worker, cursor, limit) do
          {:ok, WorkerMaintenance.page(control, usage, records, cursor, limit, now)}
        end
      else
        error(:validation)
      end
    end

    defp error(category), do: {:error, %Error{category: category, operation: :worker_control}}
  else
    # Published example apps retain their older dependency and behavior.
    def capabilities(_context), do: %{}
    def admit(_context, _worker), do: :ok
    def admit_change(_context, _before, _after), do: :ok
  end
end
