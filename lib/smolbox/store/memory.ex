defmodule SmolBox.Store.Memory do
  @moduledoc """
  Explicitly ephemeral, bounded store for tests and local development.

  The GenServer serializes transactions in one BEAM. Stopping it loses identities,
  claims, reservations and cleanup work; worker machines may remain. Never use it
  as a fallback for unavailable durable storage. Completed records are retained,
  so the configured record/serialized-byte limits can eventually reject new work.
  The byte limit bounds encoded record data, not total BEAM RSS or caller copies.
  """
  use GenServer
  @behaviour SmolBox.Store

  alias SmolBox.{Error, Execution, MachineSpec, Store, Validation}
  alias SmolBox.Store.{Codec, RecordOps}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name)

    server_options = if name, do: [name: name], else: []

    with {:ok, config} <-
           NimbleOptions.validate(options,
             max_records: [type: :pos_integer, default: 256],
             max_bytes: [type: :pos_integer, default: 67_108_864]
           ) do
      if config[:max_records] <= 10_000 and config[:max_bytes] <= 1_073_741_824 do
        GenServer.start_link(__MODULE__, config, server_options)
      else
        {:error, :invalid_bounds}
      end
    end
  end

  @impl GenServer
  def init(config),
    do:
      {:ok,
       %{
         records: %{},
         machine_keys: %{},
         sizes: %{},
         bytes: 0,
         leases: %{},
         max_records: config[:max_records],
         max_bytes: config[:max_bytes]
       }}

  @impl Store
  def capabilities(store), do: call(store, :capabilities)
  @impl Store
  def accept(store, record, max_pending), do: call(store, {:accept, record, max_pending})
  @impl Store
  def fetch(store, key), do: call(store, {:fetch, key})
  @impl Store
  def find_machine(store, worker, name), do: call(store, {:find_machine, worker, name})
  @impl Store
  def claim_worker(store, worker, owner, now, ttl),
    do: call(store, {:claim_worker, worker, owner, now, ttl})

  @impl Store
  def claim(store, key, owner, now, ttl),
    do: call(store, {:mutate, key, {:claim, owner, now, ttl}})

  @impl Store
  def write(store, key, guard, changes, now),
    do: call(store, {:mutate, key, {:write, guard, changes, now}})

  @impl Store
  def reserve(store, key, guard, allocation, now),
    do: call(store, {:mutate, key, {:reserve, guard, allocation, now}})

  @impl Store
  def release(store, key, guard, now), do: call(store, {:mutate, key, {:release, guard, now}})
  @impl Store
  def cancel(store, key, now), do: call(store, {:mutate, key, {:cancel, now}})
  @impl Store
  def due(store, now, cursor, limit), do: call(store, {:due, now, cursor, limit})
  @impl Store
  def usage(store, worker), do: call(store, {:usage, worker})

  @impl GenServer
  def handle_call(request, _from, state) do
    {reply, state} = execute(request, state)
    {:reply, reply, state}
  end

  defp execute(:capabilities, state),
    do: {{:ok, %{schema: 1, durable: false, atomic: true}}, state}

  defp execute({:fetch, key}, state), do: {lookup(state, key), state}

  defp execute({:find_machine, worker, name}, state) do
    result =
      if Validation.identifier?(worker) and MachineSpec.valid_name?(name) do
        case Map.fetch(state.machine_keys, {worker, name}) do
          {:ok, key} -> lookup(state, key)
          :error -> error(:not_found)
        end
      else
        error(:validation)
      end

    {result, state}
  end

  defp execute({:usage, worker}, state), do: {{:ok, used(state, worker)}, state}

  defp execute({:accept, record, max_pending}, state) do
    with :ok <- RecordOps.initial(record),
         true <- Validation.integer?(max_pending, 1, 10_000) do
      accept_record(state, record, max_pending)
    else
      _invalid -> {error(:validation), state}
    end
  end

  defp execute({:claim_worker, worker, owner, now, ttl}, state) do
    with true <- Validation.identifier?(worker),
         true <- Map.has_key?(state.leases, worker) or map_size(state.leases) < 64,
         {:ok, lease} <- RecordOps.lease(state.leases[worker], owner, now, ttl) do
      {{:ok, lease}, put_in(state.leases[worker], lease)}
    else
      {:error, _error} = error -> {error, state}
      _invalid -> {error(:validation), state}
    end
  end

  defp execute({:mutate, key, operation}, state) do
    with {:ok, record} <- lookup(state, key),
         {:ok, updated} <- mutate(record, operation, state),
         {:ok, state} <- put_record(state, updated) do
      {{:ok, updated}, state}
    else
      {:error, _error} = error -> {error, state}
    end
  end

  defp execute({:due, now, cursor, limit}, state) do
    if Execution.timestamp?(now) and valid_cursor?(cursor) and Validation.integer?(limit, 1, 100) do
      records =
        state.records
        |> Map.values()
        |> Enum.filter(
          &(RecordOps.due?(&1, now) and (cursor == nil or RecordOps.cursor(&1) > cursor))
        )
        |> Enum.sort_by(&RecordOps.cursor/1)
        |> Enum.take(limit + 1)

      page = Enum.take(records, limit)
      next = if length(records) > limit, do: RecordOps.cursor(List.last(page))
      {{:ok, page, next}, state}
    else
      {error(:validation), state}
    end
  end

  defp accept_record(state, record, max_pending) do
    case Map.fetch(state.records, Execution.key(record)) do
      {:ok, %{fingerprint: fingerprint} = existing} when fingerprint == record.fingerprint ->
        {{:ok, existing, :existing}, state}

      {:ok, _conflict} ->
        {error(:identity_conflict), state}

      :error ->
        insert_record(state, record, max_pending)
    end
  end

  defp insert_record(state, record, max_pending) do
    pending = Enum.count(state.records, fn {_key, record} -> record.state == :accepted end)

    if pending < max_pending and map_size(state.records) < state.max_records do
      case put_record(state, record) do
        {:ok, next} -> {{:ok, record, :inserted}, next}
        error -> {error, state}
      end
    else
      {error(:admission_exhausted), state}
    end
  end

  defp mutate(record, {:claim, owner, now, ttl}, state),
    do: RecordOps.claim(record, state.leases[record.worker_id], owner, now, ttl)

  defp mutate(record, {:cancel, now}, _state), do: RecordOps.cancel(record, now)

  defp mutate(record, {:write, guard, changes, now}, state) do
    with :ok <- RecordOps.guard(record, guard, state.leases[record.worker_id], now),
         do: Execution.transition(record, changes, now)
  end

  defp mutate(record, {:release, guard, now}, state) do
    with :ok <- RecordOps.guard(record, guard, state.leases[record.worker_id], now),
         do: RecordOps.release(record, now)
  end

  defp mutate(record, {:reserve, guard, {worker, machine, capacity}, now}, state) do
    with :ok <- RecordOps.guard(record, guard, state.leases[record.worker_id], now) do
      RecordOps.reservation(
        record,
        worker,
        machine,
        state.leases[worker],
        capacity,
        used(state, worker),
        now
      )
    end
  end

  defp lookup(state, key) do
    case Map.fetch(state.records, key) do
      {:ok, record} -> {:ok, record}
      :error -> error(:not_found)
    end
  end

  defp put_record(state, record) do
    with {:ok, machine_keys} <- machine_index(state.machine_keys, record),
         {:ok, bytes} <- Codec.encode(record) do
      key = Execution.key(record)
      size = byte_size(bytes)
      total = state.bytes - Map.get(state.sizes, key, 0) + size

      if total <= state.max_bytes do
        {:ok,
         %{
           state
           | records: Map.put(state.records, key, record),
             machine_keys: machine_keys,
             sizes: Map.put(state.sizes, key, size),
             bytes: total
         }}
      else
        error(:admission_exhausted)
      end
    end
  end

  defp machine_index(index, %{worker_id: nil}), do: {:ok, index}

  defp machine_index(index, record) do
    machine_key = {record.worker_id, record.machine_name}
    execution_key = Execution.key(record)

    case Map.fetch(index, machine_key) do
      {:ok, ^execution_key} -> {:ok, index}
      {:ok, _conflict} -> error(:identity_conflict)
      :error -> {:ok, Map.put(index, machine_key, execution_key)}
    end
  end

  defp used(state, worker) do
    Enum.reduce(state.records, RecordOps.empty_usage(), fn {_key, record}, acc ->
      if record.worker_id == worker and record.reservation != nil do
        Map.merge(acc, record.reservation, &add_resource/3)
      else
        acc
      end
    end)
  end

  defp add_resource(_resource, current, amount), do: current + amount

  defp valid_cursor?(nil), do: true

  defp valid_cursor?({now, scope, id}),
    do: Execution.timestamp?(now) and Validation.identifier?(scope) and Validation.identifier?(id)

  defp valid_cursor?(_cursor), do: false

  defp call(store, request) do
    GenServer.call(store, request, 5000)
  catch
    :exit, _redacted ->
      {:error, %Error{category: :store, operation: :store, evidence: :dispatch_uncertain}}
  end

  defp error(category), do: {:error, %Error{category: category, operation: :store}}
end
