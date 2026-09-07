defmodule SmolBox.Runtime.Inspection do
  @moduledoc false
  alias SmolBox.{Client, Error, Execution, Identity, Machine, MachineSpec, Validation}
  alias SmolBox.Runtime.Session

  def page(config, worker_id, options) do
    with true <- Validation.identifier?(worker_id) and options?(options),
         worker when worker != nil <-
           Enum.find(config.workers, &(&1.client.worker.id == worker_id)),
         {:ok, machines} <- Client.list(bounded_client(worker.client)) do
      report(config, worker_id, machines, options)
    else
      false -> Session.error(:validation, :inspect)
      nil -> Session.error(:not_found, :worker)
      {:error, _error} = error -> error
    end
  end

  defp report(config, worker_id, machines, options) do
    candidates = Enum.filter(machines, &Identity.candidate?(config.namespace, &1.name))
    limit = Keyword.get(options, :limit, 20)
    cursor = Keyword.get(options, :cursor)

    remaining =
      candidates
      |> Enum.sort_by(& &1.name)
      |> Enum.filter(&(cursor == nil or &1.name > cursor))

    page = Enum.take(remaining, limit)

    {:ok,
     %{
       worker_id: worker_id,
       checked_at_ms: config.clock.now(),
       foreign_count: length(machines) - length(candidates),
       candidates: observations(config, worker_id, page),
       next_cursor: if(length(remaining) > limit, do: List.last(page).name)
     }}
  end

  defp observations(config, worker, machines) do
    machines
    |> Task.async_stream(&lookup(config, worker, &1),
      max_concurrency: 4,
      timeout: 500,
      on_timeout: :kill_task
    )
    |> Enum.zip(machines)
    |> Enum.map(fn
      {{:ok, finding}, _machine} -> finding
      {_failed, machine} -> finding(machine, :unavailable)
    end)
  end

  defp lookup(config, worker, machine) do
    case Session.store(config, :find_machine, [worker, machine.name]) do
      {:ok, %Execution{} = record} ->
        classify(record, worker, machine)

      {:error, %Error{category: :not_found}} ->
        finding(machine, :untracked)

      _unavailable ->
        finding(machine, :unavailable)
    end
  end

  defp classify(record, worker, machine) do
    if Execution.validate(record) == :ok and record.worker_id == worker and
         record.machine_name == machine.name do
      machine
      |> finding(status(record, machine))
      |> Map.put(:execution, Execution.key(record))
      |> Map.put(:record_version, record.version)
    else
      finding(machine, :unavailable)
    end
  end

  defp status(%{created_machine: nil}, _machine), do: :unverified

  defp status(record, machine) do
    cond do
      not Machine.same_incarnation?(record.created_machine, machine) -> :conflict
      record.cleanup == :complete -> :cleanup_conflict
      true -> :owned
    end
  end

  defp finding(machine, status),
    do: %{machine_name: machine.name, observed_state: machine.state, status: status}

  defp bounded_client(client),
    do: %{
      client
      | worker: %{
          client.worker
          | operation_timeout_ms: min(client.worker.operation_timeout_ms, 1000),
            max_response_bytes: min(client.worker.max_response_bytes, 2_097_152)
        }
    }

  defp options?(options) do
    Validation.keys?(options, [:cursor, :limit]) and
      Validation.integer?(Keyword.get(options, :limit, 20), 1, 100) and
      (Keyword.get(options, :cursor) == nil or MachineSpec.valid_name?(options[:cursor]))
  end
end
