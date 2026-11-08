defmodule SmolBox.Embedded.Call do
  @moduledoc false
  alias SmolBox.Backend.EmbeddedContext
  alias SmolBox.Embedded.{Config, LogStream, Protocol}
  alias SmolBox.Error

  # Capture once before durable intent writes. A failed capture remains fenced
  # unavailable, rather than resolving a replacement owner later in a Task.
  def pin(%EmbeddedContext{pinned: true} = context, _budget), do: context

  def pin(context, budget) do
    owner = GenServer.whereis(context.server)
    context = %{context | server: owner}
    budget = %{budget | timeout_ms: min(budget.timeout_ms, 1000)}

    case health(context, budget) do
      {:ok, %{status: status, epoch: epoch}} when status in [:ready, :reconciling] ->
        %{context | pinned: true, epoch: epoch}

      _unavailable ->
        %{context | pinned: true, server: nil, epoch: nil}
    end
  end

  def run(context, request, budget, input \\ <<>>, callback \\ nil) do
    state = %{
      context: context,
      request: request,
      budget: budget,
      input: input,
      callback: callback,
      log_parser:
        if(is_map(request) and request["operation"] == "logs",
          do: LogStream.new(request["max_bytes"])
        ),
      flags: :atomics.new(2, []),
      deadline: now() + budget.timeout_ms,
      grace: if(request == :health, do: 0, else: context.config.limits.cancel_grace_ms),
      output: %{stdout: [], stderr: [], file: []},
      bytes: 0,
      error: nil,
      cancelled: false
    }

    parent = self()
    token = make_ref()
    {worker, monitor} = spawn_monitor(fn -> send(parent, {token, protected(state)}) end)
    spawn(fn -> watch(parent, worker) end)

    try do
      receive do
        {^token, result} -> result
        {:DOWN, ^monitor, :process, ^worker, _reason} -> failure(state.flags, :unknown)
      after
        budget.timeout_ms + state.grace + 100 -> timeout(worker, monitor, token, state.flags)
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def health(context, budget), do: run(context, :health, budget)

  defp timeout(worker, monitor, token, flags) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    after
      100 -> :ok
    end

    receive do
      {^token, _late} -> :ok
    after
      0 -> :ok
    end

    failure(flags, :expired)
  end

  defp watch(parent, worker) do
    parent_ref = Process.monitor(parent)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^parent_ref, :process, ^parent, _reason} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp protected(state) do
    perform(state)
  rescue
    _redacted -> failure(state.flags, :unknown)
  catch
    _kind, _redacted -> failure(state.flags, :unknown)
  end

  defp perform(state) do
    owner = if state.context.server, do: GenServer.whereis(state.context.server)

    if is_pid(owner) and node(owner) == node(),
      do:
        observed(Map.merge(state, %{owner: owner, bridge: EmbeddedContext.bridge(state.context)})),
      else: failure(state.flags, :unknown)
  end

  defp observed(state) do
    monitor = Process.monitor(state.owner)

    try do
      with {:ok, health} <- state.bridge.health(state.owner),
           true <- identity?(health, state.context.config),
           true <- not state.context.pinned or health.epoch == state.context.epoch,
           true <- now() < state.deadline do
        submit(
          %{state | budget: %{state.budget | timeout_ms: max(1, state.deadline - now())}}
          |> Map.put(:monitor, monitor),
          health
        )
      else
        {:error, %Error{} = error} -> {:error, error}
        _unapproved -> {:error, %Error{category: :identity_conflict, operation: :embedded}}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp identity?(health, config),
    do:
      health.target_id == config.id and health.generation == config.domain_generation and
        health.package_identity == config.package_identity and
        health.package_manifest_sha256 == config.package_manifest_sha256

  defp submit(%{request: :health}, health), do: {:ok, health}

  defp submit(state, health) do
    if health.status == :ready or
         (health.status == :reconciling and
            state.request["operation"] in ~w(inspect inspect_creation)) do
      :atomics.put(state.flags, 1, 1)

      case state.bridge.submit(state.owner, state.request, state.budget, self(), health.epoch) do
        {:ok, handle} -> consume(Map.put(state, :handle, handle))
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      {:error, %Error{category: :unknown, operation: :embedded}}
    end
  end

  defp consume(%{handle: handle, monitor: monitor, owner: owner} = state) do
    receive do
      {:smolbox_embedded, ^handle, :accepted} ->
        consume(state)

      {:smolbox_embedded, ^handle, {:output, stream, bytes}} ->
        output(state, stream, bytes)

      {:smolbox_embedded, ^handle, {:terminal, outcome, overlay}} ->
        terminal(state, outcome, overlay)

      {:smolbox_embedded, ^handle, {kind, %Error{} = error}}
      when kind in [:bridge_error, :channel_lost] ->
        {:error, error}

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        failure(state.flags, :unknown)
    after
      0 -> advance(state)
    end
  end

  defp output(state, :log, bytes) when is_binary(bytes) do
    case LogStream.feed(state.log_parser, bytes) do
      {:ok, parser, lines} ->
        next = Enum.reduce(lines, %{state | log_parser: parser}, &log_callback/2)
        output(next, :file, bytes)

      :error ->
        consume(
          cancel(state, %Error{
            category: :protocol,
            operation: :logs,
            evidence: :dispatch_uncertain
          })
        )
    end
  end

  defp output(state, stream, bytes)
       when stream in [:stdout, :stderr, :file] and is_binary(bytes) do
    if state.bytes + byte_size(bytes) <= state.budget.max_response_bytes do
      next = %{
        state
        | output: Map.update!(state.output, stream, &[bytes | &1]),
          bytes: state.bytes + byte_size(bytes)
      }

      next = stream_callback(next, {stream, bytes})

      case state.bridge.acknowledge(state.owner, state.handle, byte_size(bytes)) do
        :ok -> consume(next)
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      consume(
        cancel(state, %Error{
          category: :output_limit,
          operation: :embedded,
          evidence: :dispatch_uncertain
        })
      )
    end
  end

  defp output(state, _stream, _bytes), do: failure(state.flags, :protocol)

  defp log_callback(_line, %{callback: nil} = state), do: state

  defp log_callback(line, state) do
    state.callback.({:log, line})
    state
  rescue
    _ -> %{state | callback: nil}
  catch
    _, _ -> %{state | callback: nil}
  end

  defp stream_callback(%{request: %{"operation" => "exec_stream"}} = state, event),
    do: notify_stream(state, event)

  defp stream_callback(state, {stream, bytes}) do
    if is_function(state.callback, 1) and state.log_parser == nil,
      do: state.callback.({stream, bytes})

    state
  end

  defp notify_stream(%{callback: nil} = state, _event), do: state

  defp notify_stream(state, event) do
    state.callback.(event)
    state
  rescue
    _ -> %{state | callback: nil}
  catch
    _, _ -> %{state | callback: nil}
  end

  defp exit_callback(%{request: %{"operation" => "exec_stream"}} = state, %{
         "observed_exit" => exit
       })
       when is_integer(exit), do: notify_stream(state, {:exit, exit})

  defp exit_callback(state, _outcome), do: state

  defp advance(state) do
    cond do
      now() >= state.deadline + state.grace ->
        failure(state.flags, :expired)

      now() >= state.deadline ->
        state
        |> cancel(%Error{category: :expired, operation: :embedded, evidence: :dispatch_uncertain})
        |> pause()

      state.input != <<>> ->
        upload(state)

      true ->
        pause(state)
    end
  end

  defp cancel(%{cancelled: true} = state, _error), do: state

  defp cancel(state, error) do
    state.bridge.cancel(state.owner, state.handle)
    %{state | cancelled: true, input: <<>>, error: state.error || error}
  end

  defp pause(state) do
    Process.sleep(5)
    consume(state)
  end

  defp upload(state) do
    size = min(byte_size(state.input), 65_536)
    <<chunk::binary-size(^size), rest::binary>> = state.input

    case state.bridge.upload(state.owner, state.handle, chunk) do
      :ok -> consume(%{state | input: rest})
      {:error, %Error{category: :admission_exhausted}} -> pause(state)
      {:error, %Error{} = error} -> consume(cancel(state, error))
    end
  end

  defp terminal(state, outcome, overlay) do
    if Protocol.valid_outcome?(outcome, Config.protocol_major(state.context.config)) and
         log_terminal?(state, outcome) do
      if is_integer(outcome["observed_exit"]),
        do: :atomics.put(state.flags, 2, outcome["observed_exit"] + 2_147_483_649)

      state = exit_callback(state, outcome)

      error =
        state.error || overlay ||
          if(now() > state.deadline,
            do: %Error{category: :expired, operation: :embedded, evidence: :dispatch_uncertain}
          )

      output =
        Map.new(state.output, fn {stream, chunks} ->
          {stream, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        end)

      {:ok, outcome, output, error}
    else
      failure(state.flags, :protocol)
    end
  end

  defp log_terminal?(%{log_parser: nil}, _outcome), do: true

  defp log_terminal?(state, %{"result" => "logs", "completion" => "completed"} = outcome),
    do:
      LogStream.complete?(state.log_parser) and state.log_parser.count == outcome["lines"] and
        state.log_parser.bytes == outcome["bytes"]

  defp log_terminal?(_state, _outcome), do: true

  defp failure(flags, category) do
    exit = :atomics.get(flags, 2)

    evidence =
      cond do
        exit > 0 -> :exited
        :atomics.get(flags, 1) == 0 -> :not_dispatched
        true -> :dispatch_uncertain
      end

    {:error,
     %Error{
       category: category,
       operation: :embedded,
       evidence: evidence,
       exit_code: if(exit > 0, do: exit - 2_147_483_649)
     }}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
