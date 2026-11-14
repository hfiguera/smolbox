defmodule SmolBox.Kubernetes.Operation do
  @moduledoc false
  alias SmolBox.Backend.Budget
  alias SmolBox.Error
  alias SmolBox.Kubernetes.Config

  @enforce_keys [:config, :budget, :deadline, :name, :bytes]
  @derive {Inspect, only: [:name]}
  defstruct @enforce_keys

  def new(config, budget, name) do
    with :ok <- Config.validate(config),
         true <- Budget.valid?(budget),
         {:ok, budget} <- Budget.constrain(config.budget, Map.to_list(Map.from_struct(budget))) do
      {:ok,
       %__MODULE__{
         config: config,
         budget: budget,
         deadline: now() + budget.timeout_ms,
         name: name,
         bytes: :atomics.new(2, [])
       }}
    else
      _ -> error(:validation, name, :not_dispatched)
    end
  end

  def remaining(operation), do: max(0, operation.deadline - now())
  def budget(operation), do: %{operation.budget | timeout_ms: max(1, remaining(operation))}
  def now, do: System.monotonic_time(:millisecond)

  def error(category, name, evidence),
    do: {:error, %Error{category: category, operation: name, evidence: evidence}}

  # Opaque host callbacks cannot report every transport byte to the API client.
  # Reserve their entire granted allowance first; unused bytes are not refunded.
  # This keeps combined API, node-proof and application IO within one operation
  # limit without changing the public Backend.Budget or extension callbacks.
  @doc false
  def node_budget(operation) do
    request_left = operation.budget.max_request_bytes - :atomics.get(operation.bytes, 1)
    response_left = response_left(operation)
    request = min(65_544, div(request_left, 4))
    response = min(65_544, div(response_left, 4))

    if request > 0 and response > 0 do
      account(operation, 1, request)
      account(operation, 2, response)

      {:ok, %{budget(operation) | max_request_bytes: request, max_response_bytes: response}}
    else
      error(:output_limit, operation.name, :not_dispatched)
    end
  end

  # A request owns its socket and credential resolver. Killing the outer caller
  # also kills this isolated worker; callback exceptions never escape or log data.
  def run(operation, function) do
    caller = self()
    tag = make_ref()
    sent = :atomics.new(1, [])

    {pid, monitor} =
      spawn_monitor(fn -> send(caller, {tag, protect(operation, sent, function)}) end)

    spawn(fn -> guard(caller, pid) end)

    try do
      receive do
        {^tag, result} -> result
        {:DOWN, ^monitor, :process, ^pid, _} -> failure(operation, sent, :transport)
      after
        remaining(operation) ->
          Process.exit(pid, :kill)
          await_exit(pid, monitor, tag)
          failure(operation, sent, :expired)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def dispatched(sent), do: :atomics.put(sent, 1, 1)
  def account(operation, index, size), do: :atomics.add_get(operation.bytes, index, size)

  def response_left(operation),
    do: max(0, operation.budget.max_response_bytes - :atomics.get(operation.bytes, 2))

  defp protect(operation, sent, function) do
    if remaining(operation) > 0, do: function.(sent), else: failure(operation, sent, :expired)
  rescue
    _ -> failure(operation, sent, :transport)
  catch
    _, _ -> failure(operation, sent, :transport)
  end

  defp failure(operation, sent, category),
    do:
      error(
        category,
        operation.name,
        if(:atomics.get(sent, 1) == 0, do: :not_dispatched, else: :dispatch_uncertain)
      )

  defp guard(caller, worker) do
    refs = %{Process.monitor(caller) => :caller, Process.monitor(worker) => :worker}

    receive do
      {:DOWN, ref, :process, _, _} ->
        if refs[ref] == :caller, do: Process.exit(worker, :kill)
    end
  end

  defp await_exit(pid, monitor, tag) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      100 -> :ok
    end

    receive do
      {^tag, _} -> :ok
    after
      0 -> :ok
    end
  end
end
