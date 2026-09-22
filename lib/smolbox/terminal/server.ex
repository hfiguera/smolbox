defmodule SmolBox.Terminal.Server do
  @moduledoc false
  use GenServer
  alias SmolBox.Error
  alias SmolBox.Terminal.{Connection, Handle, Spec, Wire}

  def start(client, name, spec, consumer, observer \\ self()) do
    token = make_ref()

    case GenServer.start(__MODULE__, {client, name, spec, observer, consumer, token}) do
      {:ok, pid} -> {:ok, %Handle{pid: pid, token: token}}
      {:error, %Error{} = error} -> {:error, error}
      _failed -> failure(:transport)
    end
  end

  def call(%Handle{pid: pid, token: token}, request),
    do: GenServer.call(pid, {token, request}, 10_000)

  def safe_call(%Handle{} = handle, request) do
    call(handle, request)
  catch
    :exit, _redacted -> failure(:unknown)
  end

  def safe_call(_handle, _request), do: failure(:validation)

  def retire_closed(table, limit) do
    if :ets.info(table, :size) >= limit do
      Enum.each(:ets.tab2list(table), &retire_entry(table, &1))
    end
  end

  defp retire_entry(table, {_key, handle} = entry) do
    safe_call(handle, :retire_closed)
    # A killed server cannot run terminate/2. Do not retain its dead handle
    # indefinitely in a long-lived controller's registry.
    if not Process.alive?(handle.pid), do: :ets.delete_object(table, entry)
  end

  @impl GenServer
  def init({client, name, spec, observer, consumer, token}) do
    # Monitor before opening: a vanished owner cannot leave an orphaned socket.
    observer_ref = Process.monitor(observer)

    case Connection.open(client.worker, name, spec) do
      {:ok, connection} ->
        now = now()

        state = %{
          connection: connection,
          spec: spec,
          observer: observer,
          observer_ref: observer_ref,
          consumer: consumer,
          consumer_ref: if(consumer, do: Process.monitor(consumer)),
          token: token,
          registry: nil,
          input_left: client.worker.max_request_bytes,
          queue: :queue.new(),
          bytes: 0,
          count: 0,
          outcome: nil,
          started: false,
          opened_at: now,
          active_at: now,
          close_at: nil
        }

        send(self(), :poll)
        {:ok, state}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call({token, :bind}, {caller, _tag}, %{token: token} = state) do
    cond do
      state.consumer == caller ->
        {:reply, :ok, state}

      state.consumer != nil ->
        {:reply, failure(:identity_conflict), state}

      true ->
        {:reply, :ok, %{state | consumer: caller, consumer_ref: Process.monitor(caller)}}
    end
  end

  def handle_call({token, :retire_closed}, _from, %{token: token, connection: nil} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({token, :retire_closed}, _from, %{token: token} = state),
    do: {:reply, :ok, state}

  def handle_call(
        {token, {:register, table, key}},
        {caller, _tag},
        %{token: token, observer: caller} = state
      ) do
    :ets.insert(table, {key, %Handle{pid: self(), token: token}})
    {:reply, :ok, %{state | registry: {table, key}}}
  end

  def handle_call(
        {token, {:shutdown, operation}},
        {caller, _tag},
        %{token: token, observer: caller} = state
      ) do
    category = if operation == :terminal_session, do: :expired, else: :unknown
    {:reply, :ok, finish(state, uncertain(category, operation))}
  end

  def handle_call({token, request}, {caller, _tag}, %{token: token, consumer: caller} = state),
    do: consumer_call(request, state)

  def handle_call(_request, _from, state), do: {:reply, failure(:authentication), state}

  defp consumer_call(:next, state) do
    case :queue.out(state.queue) do
      {{:value, bytes}, queue} ->
        {:reply, {:ok, {:output, bytes}},
         %{state | queue: queue, bytes: state.bytes - byte_size(bytes), count: state.count - 1}}

      {:empty, _queue} ->
        if state.outcome,
          do: {:stop, :normal, {:ok, {:closed, state.outcome}}, state},
          else: {:reply, :empty, state}
    end
  end

  defp consumer_call(:close, %{outcome: nil, close_at: nil} = state) do
    case Connection.send_frame(state.connection, :close) do
      {:ok, connection} ->
        {:reply, :ok, %{state | connection: connection, close_at: now() + state.spec.close_ms}}

      {:error, error} ->
        {:reply, {:error, error}, finish(state, uncertain(:transport, :terminal_close))}
    end
  end

  defp consumer_call(:close, state), do: {:reply, :ok, state}

  defp consumer_call(_request, %{outcome: outcome} = state) when not is_nil(outcome),
    do: {:reply, failure(:unknown), state}

  defp consumer_call(_request, %{close_at: deadline} = state) when not is_nil(deadline),
    do: {:reply, failure(:unknown), state}

  defp consumer_call({:input, bytes}, state) when is_binary(bytes) do
    if byte_size(bytes) in 1..state.spec.max_input_bytes,
      do: transmit(state, {:binary, bytes}),
      else: {:reply, failure(:validation), state}
  end

  defp consumer_call({:resize, cols, rows}, state) do
    if Spec.dimensions?(cols, rows),
      do: transmit(state, {:text, Jason.encode!(%{type: "resize", cols: cols, rows: rows})}),
      else: {:reply, failure(:validation), state}
  end

  defp consumer_call(_request, state), do: {:reply, failure(:validation), state}

  defp transmit(state, {_kind, bytes} = frame) do
    if byte_size(bytes) > state.input_left do
      result = uncertain(:output_limit, :terminal)
      {:reply, result, finish(state, result)}
    else
      case Connection.send_frame(state.connection, frame) do
        {:ok, connection} ->
          {:reply, :ok,
           %{
             state
             | connection: connection,
               active_at: now(),
               input_left: state.input_left - byte_size(bytes)
           }}

        {:error, error} ->
          {:reply, {:error, error}, finish(state, {:error, error})}
      end
    end
  end

  @impl GenServer
  def handle_info(:poll, %{outcome: nil} = state) do
    next =
      case expired(state) do
        nil -> poll(state)
        operation -> finish(state, uncertain(:expired, operation))
      end

    if next.outcome == nil, do: Process.send_after(self(), :poll, 5)
    {:noreply, next}
  end

  def handle_info(:poll, state), do: {:noreply, state}
  def handle_info(:retire, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when ref == state.observer_ref or ref == state.consumer_ref do
    {:stop, :normal, finish(state, uncertain(:unknown, :terminal_consumer))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp expired(state) do
    cond do
      state.close_at != nil and now() >= state.close_at ->
        :terminal_close

      now() - state.opened_at >= state.spec.session_ms ->
        :terminal_session

      state.consumer == nil and now() - state.opened_at >= state.spec.attach_ms ->
        :terminal_consumer

      now() - state.active_at >= state.spec.idle_ms ->
        :terminal_idle

      true ->
        nil
    end
  end

  defp poll(state) do
    case Connection.poll(state.connection) do
      {:ok, connection, frames} ->
        next =
          Enum.reduce_while(frames, %{state | connection: connection}, &reduce_frame/2)

        if next.outcome != nil, do: finish(next, next.outcome), else: next

      {:error, error} ->
        operation = if state.close_at, do: :terminal_close, else: :terminal
        finish(state, {:error, %{error | operation: operation}})
    end
  end

  defp reduce_frame(frame, state) do
    case frame(state, frame) do
      {:ok, next} -> {:cont, next}
      {:error, error} -> {:halt, finish(state, {:error, error})}
    end
  end

  defp frame(%{outcome: outcome} = state, {:close, _code, _reason}) when not is_nil(outcome),
    do: {:ok, state}

  defp frame(%{outcome: outcome}, _frame) when not is_nil(outcome), do: failure(:protocol)

  defp frame(state, frame) do
    case Wire.event(frame) do
      {:ok, {:output, bytes}} ->
        output(state, bytes)

      {:ok, {:exit, result}} ->
        {:ok, %{state | outcome: {:ok, result}}}

      {:ok, {:pong, bytes}} ->
        with {:ok, connection} <- Connection.send_frame(state.connection, {:pong, bytes}),
             do: {:ok, %{state | connection: connection}}

      {:ok, :ignore} ->
        {:ok, state}

      {:error, category} ->
        uncertain(category, if(state.close_at, do: :terminal_close, else: :terminal))
    end
  end

  defp output(state, <<>>), do: {:ok, state}

  defp output(state, bytes) do
    if state.bytes + byte_size(bytes) <= state.spec.max_buffer_bytes and state.count < 1024 do
      if not state.started, do: notify(state, {state.token, :terminal_started})

      {:ok,
       %{
         state
         | queue: :queue.in(bytes, state.queue),
           bytes: state.bytes + byte_size(bytes),
           count: state.count + 1,
           active_at: now(),
           started: true
       }}
    else
      failure(:output_limit)
    end
  end

  defp finish(%{connection: nil} = state, _outcome), do: state

  defp finish(state, outcome) do
    Connection.send_frame(state.connection, :close)
    Connection.close(state.connection)
    notify(state, {state.token, :terminal_outcome, outcome})
    Process.demonitor(state.observer_ref, [:flush])
    Process.send_after(self(), :retire, 30_000)
    %{state | connection: nil, outcome: outcome}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.connection, do: Connection.close(state.connection)

    if state.registry do
      {table, key} = state.registry
      :ets.delete_object(table, {key, %Handle{pid: self(), token: state.token}})
    end

    :ok
  rescue
    _gone_table -> :ok
  end

  @impl GenServer
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp notify(%{observer: pid, consumer: pid}, _message), do: :ok
  defp notify(state, message), do: send(state.observer, message)
  defp now, do: System.monotonic_time(:millisecond)

  defp failure(category) when category in [:validation, :authentication, :identity_conflict],
    do: {:error, %Error{category: category, operation: :terminal}}

  defp failure(category), do: uncertain(category, :terminal)

  defp uncertain(category, operation),
    do: {:error, %Error{category: category, operation: operation, evidence: :unknown}}
end
