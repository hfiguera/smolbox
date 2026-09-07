defmodule SmolBox.DurableHost.BenchmarkMetrics do
  @moduledoc false
  @behaviour SmolBox.Transport
  alias SmolBox.Transport.Req

  @limit 5000

  def open do
    __MODULE__ = :ets.new(__MODULE__, [:named_table, :ordered_set, :public])
    true = :ets.insert(__MODULE__, {:counter, 0})

    :ok =
      :telemetry.attach_many(
        __MODULE__,
        SmolBox.Telemetry.events(),
        &__MODULE__.event/4,
        nil
      )
  end

  def close do
    :telemetry.detach(__MODULE__)
    :ets.delete(__MODULE__)
  end

  def event(event, measurements, metadata, _config) do
    record(%{
      kind: :event,
      event: List.last(event),
      stage: metadata[:stage],
      execution_id: metadata[:execution_id],
      measurements: measurements
    })
  end

  @impl SmolBox.Transport
  def request(worker, request) do
    {operation, machine} = route(request)
    record(%{kind: :transport_start, operation: operation, machine: machine})
    started = System.monotonic_time(:microsecond)
    result = Req.request(worker, request)

    record(%{
      kind: :transport,
      operation: operation,
      machine: machine,
      duration_us: System.monotonic_time(:microsecond) - started,
      request_bytes: byte_size(request.body)
    })

    result
  end

  def rows do
    [{:counter, count}] = :ets.lookup(__MODULE__, :counter)
    if count > @limit, do: raise("benchmark event bound exceeded")

    for {index, row} <- :ets.tab2list(__MODULE__), is_integer(index), do: row
  end

  def execution(id, machine) do
    events = Enum.filter(rows(), &(&1[:execution_id] == id))
    requests = Enum.filter(rows(), &(&1.kind == :transport and &1.machine == machine))
    started = Enum.filter(rows(), &(&1.kind == :transport_start and &1.machine == machine))
    stages = Enum.filter(events, &(&1.event == :stop and &1.stage != nil))
    reservations = Enum.filter(events, &(&1.event == :reserved))

    %{
      stages_ms: Enum.group_by(stages, & &1.stage, & &1.measurements.duration_ms),
      queue_wait_ms: Enum.map(reservations, & &1.measurements.queue_wait_ms),
      requests_us: Enum.group_by(requests, & &1.operation, & &1.duration_us),
      transport_invocations: Enum.frequencies_by(started, & &1.operation),
      request_bytes: Enum.reduce(requests, 0, &(&1.request_bytes + &2))
    }
  end

  defp record(row) do
    index = :ets.update_counter(__MODULE__, :counter, {2, 1})
    if index <= @limit, do: :ets.insert(__MODULE__, {index, row})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp route(%{method: :post, path: "/api/v1/machines", body: body}),
    do: {:create, Jason.decode!(body)["name"]}

  defp route(request) do
    case String.split(request.path, "/", trim: true) do
      ["api", "v1", "machines", machine | rest] ->
        {operation(request.method, rest), machine}

      _worker_probe ->
        {:worker_probe, nil}
    end
  end

  defp operation(:put, ["files" | _path]), do: :upload

  defp operation(:get, ["files", "workspace", file]) when file in ["main.py", "input.bin"],
    do: :verify_input

  defp operation(:get, ["files" | _path]), do: :download
  defp operation(:post, ["start"]), do: :start
  defp operation(:post, ["stop"]), do: :stop
  defp operation(:post, ["exec" | _stream]), do: :exec
  defp operation(:delete, []), do: :delete
  defp operation(:get, []), do: :inspect
end
