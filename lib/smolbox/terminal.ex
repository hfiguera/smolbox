defmodule SmolBox.Terminal do
  @moduledoc """
  Interactive terminal sessions on owned managed image machines.

  `open/3` durably accepts an `ExecutionSpec` whose command is `Terminal.Spec` and
  returns the usual scoped execution identity. `attach/3` binds one consumer to
  its live controller-side connection; it does not reconnect a lost guest PTY.
  Use the runtime that owns the live session. Another controller cannot take over
  input. Scope authorization remains the host application's responsibility.

  Read output with `next/2`, send bytes with `input/2`, resize with `resize/3`, and
  request local closure with `close/1`. Output is a terminal byte stream. A closed
  event contains either confirmed exit evidence or a redacted uncertain failure.
  The durable result can lag live delivery; inspect or await the execution record.
  No input or terminal output is saved in the durable store.
  """
  alias SmolBox.{Error, Execution, ExecutionSpec, Machines, Runtime, Validation}
  alias SmolBox.Terminal.{Handle, Result, Server, Spec}

  @type outcome :: {:ok, Result.t()} | {:error, Error.t()}
  @type event :: {:output, binary()} | {:closed, outcome()}

  @doc "Accept terminal intent; duplicates return the same execution without opening another shell."
  @spec open(SmolBox.runtime(), Machines.handle(), ExecutionSpec.t()) ::
          {:ok, Execution.key()} | {:error, Error.t()}
  def open(runtime, machine, %ExecutionSpec{command: %Spec{}} = spec),
    do: Machines.submit(runtime, machine, spec)

  def open(_runtime, _machine, _spec), do: failure(:validation)

  @doc "Bind the first consumer to a live session on this runtime, waiting up to timeout ms."
  @spec attach(SmolBox.runtime(), Execution.key(), non_neg_integer()) ::
          {:ok, Handle.t()} | {:error, Error.t()}
  def attach(runtime, key, timeout \\ 5000) do
    if Validation.integer?(timeout, 0, 30_000),
      do: attach_until(runtime, key, now() + timeout),
      else: failure(:validation)
  end

  defp attach_until(runtime, {scope, id} = key, deadline) do
    with {:ok, record} <- SmolBox.fetch(runtime, scope, id),
         true <- is_struct(record.spec.command, Spec) do
      attach_record(runtime, key, record, deadline)
    else
      false -> failure(:validation)
      error -> error
    end
  rescue
    _redacted -> failure(:unknown)
  catch
    :exit, _redacted -> failure(:unknown)
  end

  defp attach_until(_runtime, _key, _deadline), do: failure(:validation)

  defp attach_record(runtime, key, record, deadline) do
    case Runtime.lookup_terminal(runtime, key) do
      {:ok, handle} -> with :ok <- safe_call(handle, :bind), do: {:ok, handle}
      :pending -> attach_pending(runtime, key, record, deadline)
    end
  end

  defp attach_pending(runtime, key, record, deadline) do
    cond do
      Execution.terminal?(record) or record.state == :unknown ->
        failure(:unknown)

      now() >= deadline ->
        failure(:expired)

      true ->
        receive do
        after
          10 -> attach_until(runtime, key, deadline)
        end
    end
  end

  @doc "Pull one output event or final closed event; timeout only ends this caller's wait."
  @spec next(Handle.t(), non_neg_integer()) :: {:ok, event()} | {:error, Error.t()}
  def next(handle, timeout \\ 5000) do
    if Validation.integer?(timeout, 0, 900_000),
      do: next_until(handle, now() + timeout),
      else: failure(:validation)
  end

  defp next_until(handle, deadline) do
    case safe_call(handle, :next) do
      :empty ->
        if now() >= deadline,
          do: failure(:expired),
          else:
            (receive do
             after
               5 -> next_until(handle, deadline)
             end)

      result ->
        result
    end
  end

  @doc "Send bounded terminal bytes. Ctrl-C/Ctrl-D are input, not termination guarantees."
  @spec input(Handle.t(), binary()) :: :ok | {:error, Error.t()}
  def input(handle, bytes) when is_binary(bytes) and byte_size(bytes) in 1..65_536,
    do: safe_call(handle, {:input, bytes})

  def input(_handle, _bytes), do: failure(:validation)

  @doc "Request terminal dimensions in columns and rows, each 1–65535."
  @spec resize(Handle.t(), pos_integer(), pos_integer()) :: :ok | {:error, Error.t()}
  def resize(handle, cols, rows) do
    if Spec.dimensions?(cols, rows),
      do: safe_call(handle, {:resize, cols, rows}),
      else: failure(:validation)
  end

  @doc "Request WebSocket close; wait for the closed event. Closure does not prove guest termination."
  @spec close(Handle.t()) :: :ok | {:error, Error.t()}
  def close(handle), do: safe_call(handle, :close)

  defp safe_call(handle, request), do: Server.safe_call(handle, request)
  defp now, do: System.monotonic_time(:millisecond)
  defp failure(category), do: {:error, %Error{category: category, operation: :terminal}}
end
