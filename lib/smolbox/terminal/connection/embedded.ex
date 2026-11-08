defmodule SmolBox.Terminal.Connection.Embedded do
  @moduledoc false
  @behaviour SmolBox.Terminal.Connection.Transport
  alias SmolBox.Backend.{Budget, EmbeddedContext, Features}
  alias SmolBox.Embedded.{Call, TerminalContract}
  alias SmolBox.Error
  alias SmolBox.Terminal.{Result, Spec}

  defmodule Source do
    @moduledoc false
    @enforce_keys [:owner, :bridge, :epoch, :binding, :request, :budget, :name, :spec, :deadline]
    @derive {Inspect, only: []}
    defstruct @enforce_keys
  end

  # Only the assigned backend constructs a source, after durable admission.
  # The bridge independently checks the approved package, receipt and epoch.
  def source(context, name, spec, budget) do
    with true <- Features.supports?(context.config, :terminals),
         true <- EmbeddedContext.scoped?(context) and context.name == name,
         true <- context.managed_machine != nil and context.spec.command == spec,
         :ok <- Spec.validate(spec),
         {:ok, receipt} <- EmbeddedContext.receipt(context),
         {:ok, budget} <- Budget.constrain(budget, timeout_ms: spec.session_ms),
         deadline = now() + budget.timeout_ms,
         pinned = Call.pin(context, budget),
         true <- is_pid(pinned.server) and is_binary(pinned.epoch) do
      total_input = min(budget.max_request_bytes, TerminalContract.limits()["total_input_bytes"])

      terminal =
        Map.new(Map.from_struct(spec), fn {key, value} -> {Atom.to_string(key), value} end)

      terminal = Map.put(terminal, "total_input_bytes", total_input)

      source = %Source{
        owner: pinned.server,
        bridge: EmbeddedContext.bridge(pinned),
        epoch: pinned.epoch,
        binding:
          Map.take(context.config, [
            :id,
            :domain_generation,
            :package_identity,
            :package_manifest_sha256
          ]),
        request: %{"operation" => "terminal_open", "receipt" => receipt, "terminal" => terminal},
        budget: budget,
        deadline: deadline,
        name: name,
        spec: spec
      }

      {:ok, {__MODULE__, source}}
    else
      _ -> failure(:identity_conflict)
    end
  end

  @impl true
  def open(%Source{name: name, spec: spec} = source, name, spec) do
    monitor = Process.monitor(source.owner)
    deadline = min(source.deadline, now() + 30_000)

    result =
      with true <- now() < deadline,
           {:ok, health} <- call(source, :health, [], 1000),
           true <- health_matches?(source, health),
           {:ok, handle} <-
             call(
               source,
               :submit,
               [
                 source.request,
                 %{source.budget | timeout_ms: max(1, source.deadline - now())},
                 self(),
                 source.epoch
               ],
               1000
             ) do
        state = %{
          source: source,
          monitor: monitor,
          handle: handle,
          owed: :queue.new(),
          bytes: 0,
          total: 0,
          attached: false,
          closing: false,
          done: false
        }

        opening(state, deadline)
      else
        {:error, %Error{} = error} -> {:error, error}
        _ -> failure(:identity_conflict)
      end

    if match?({:error, _}, result), do: Process.demonitor(monitor, [:flush])
    result
  end

  def open(_source, _name, _spec), do: failure(:validation)

  defp health_matches?(source, health),
    do:
      health.status == :ready and health.epoch == source.epoch and
        health.target_id == source.binding.id and
        health.generation == source.binding.domain_generation and
        health.package_identity == source.binding.package_identity and
        health.package_manifest_sha256 == source.binding.package_manifest_sha256

  defp opening(%{handle: handle, monitor: monitor, source: %{owner: owner}} = state, deadline) do
    receive do
      {:smolbox_embedded, ^handle, :accepted} ->
        opening(state, deadline)

      {:smolbox_embedded, ^handle, :terminal_opened} ->
        {:ok, state, state.source.request["terminal"]["total_input_bytes"]}

      {:smolbox_embedded, ^handle, _event} ->
        close(state)
        failure(:unknown)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        failure(:unknown)
    after
      max(0, deadline - now()) ->
        close(state)
        failure(:expired)
    end
  end

  @impl true
  def input_cost(_state, {:input, bytes}), do: byte_size(bytes)
  def input_cost(_state, {:resize, _cols, _rows}), do: 4

  @impl true
  def send(%{done: true} = state, :close), do: {:ok, state}
  def send(%{closing: true} = state, :close), do: {:ok, state}

  def send(%{attached: false, closing: false} = state, :attach),
    do: control(state, %{"action" => "attach"}, :attached)

  def send(%{attached: true, closing: false} = state, {:input, bytes}),
    do: control(state, %{"action" => "input", "data_base64" => Base.encode64(bytes)}, nil)

  def send(%{attached: true, closing: false} = state, {:resize, cols, rows}),
    do: control(state, %{"action" => "resize", "cols" => cols, "rows" => rows}, nil)

  def send(%{attached: true, closing: false} = state, :close),
    do: control(state, %{"action" => "close"}, :closing)

  def send(_state, _command), do: failure(:validation)

  defp control(state, action, flag) do
    case call(state.source, :terminal_control, [state.handle, action], 1000) do
      :ok -> {:ok, if(flag, do: Map.put(state, flag, true), else: state)}
      {:error, %Error{} = error} -> {:error, %{error | operation: :terminal}}
    end
  end

  @impl true
  def poll(state), do: {:ok, state, []}

  @impl true
  def handle_message(
        %{handle: handle, done: false} = state,
        {:smolbox_embedded, handle, {:output, :terminal, bytes}}
      )
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= 65_536 do
    if state.bytes + byte_size(bytes) <= state.source.spec.max_buffer_bytes and
         :queue.len(state.owed) < 64 do
      {:ok,
       %{
         state
         | owed: :queue.in(byte_size(bytes), state.owed),
           bytes: state.bytes + byte_size(bytes),
           total: state.total + byte_size(bytes)
       }, [{:output, bytes}]}
    else
      failure(:output_limit)
    end
  end

  def handle_message(
        %{handle: handle, done: false} = state,
        {:smolbox_embedded, handle, {:terminal, outcome, overlay}}
      ) do
    if TerminalContract.outcome?(outcome) and outcome["completion"] == "exited" and
         outcome["output_bytes"] == state.total and overlay == nil do
      {:ok, %{state | done: true}, [{:exit, %Result{exit_code: outcome["observed_exit"]}}]}
    else
      failure(:unknown, observed_exit(outcome))
    end
  end

  def handle_message(%{handle: handle}, {:smolbox_embedded, handle, {kind, %Error{} = error}})
      when kind in [:bridge_error, :channel_lost],
      do: {:error, %{error | operation: :terminal, evidence: :unknown}}

  def handle_message(
        %{monitor: monitor, source: %{owner: owner}},
        {:DOWN, monitor, :process, owner, _reason}
      ),
      do: failure(:unknown)

  def handle_message(%{handle: handle}, {:smolbox_embedded, handle, _invalid}),
    do: failure(:protocol)

  def handle_message(_state, _message), do: :ignore

  @impl true
  def acknowledge(state, bytes) do
    with {:ok, queue} <- consumed(state.owed, bytes),
         :ok <- call(state.source, :acknowledge, [state.handle, bytes], 1000) do
      {:ok, %{state | owed: queue, bytes: state.bytes - bytes}}
    else
      _ -> failure(:unknown)
    end
  end

  defp consumed(queue, 0), do: {:ok, queue}

  defp consumed(queue, bytes) when bytes > 0 do
    case :queue.out(queue) do
      {{:value, size}, rest} when size <= bytes -> consumed(rest, bytes - size)
      _ -> :error
    end
  end

  defp consumed(_queue, _bytes), do: :error

  @impl true
  def close(state) do
    try do
      if not state.done, do: closing_call(state.source, :cancel, [state.handle])
      # Discard this closed bridge subscription after cancellation or collected
      # completion. This grants no live-session consumption and preserves the
      # controller's already validated prefix in its separately bounded buffer.
      if state.bytes > 0,
        do: closing_call(state.source, :acknowledge, [state.handle, state.bytes])
    catch
      :exit, _ -> :ok
    after
      Process.demonitor(state.monitor, [:flush])
    end

    :ok
  end

  defp observed_exit(outcome) when is_map(outcome), do: outcome["observed_exit"]
  defp observed_exit(_outcome), do: nil

  defp call(source, operation, args, ceiling) do
    timeout = min(ceiling, source.deadline - now())

    if timeout > 0,
      do: apply(source.bridge, operation, [source.owner | args] ++ [timeout]),
      else: failure(:expired)
  end

  defp closing_call(source, operation, args),
    do:
      apply(
        source.bridge,
        operation,
        [source.owner | args] ++ [max(1, min(source.spec.close_ms, 1000))]
      )

  defp now, do: System.monotonic_time(:millisecond)

  defp failure(category, exit \\ nil),
    do:
      {:error,
       %Error{category: category, operation: :terminal, evidence: :unknown, exit_code: exit}}
end
