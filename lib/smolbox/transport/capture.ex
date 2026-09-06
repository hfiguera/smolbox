defmodule SmolBox.Transport.Capture do
  @moduledoc false

  alias SmolBox.{Error, Result}
  alias SmolBox.Wire.SSE

  defstruct [
    :mode,
    :max_bytes,
    :max_output,
    :on_event,
    :exit_code,
    bytes: 0,
    output_bytes: 0,
    chunks: [],
    stdout: [],
    stderr: [],
    parser: %SSE{}
  ]

  @type t :: %__MODULE__{
          mode: :buffer | :sse,
          max_bytes: pos_integer(),
          max_output: pos_integer() | nil,
          on_event: (SSE.event() -> any()) | nil,
          exit_code: integer() | nil,
          bytes: non_neg_integer(),
          output_bytes: non_neg_integer(),
          chunks: [binary()],
          stdout: [binary()],
          stderr: [binary()],
          parser: SSE.t()
        }

  @spec new(SmolBox.Transport.request()) :: t()
  def new(%{mode: :buffer, max_bytes: max}), do: %__MODULE__{mode: :buffer, max_bytes: max}

  def new(%{mode: {:sse, max_output, callback}, max_bytes: max}) do
    %__MODULE__{mode: :sse, max_bytes: max, max_output: max_output, on_event: callback}
  end

  @spec feed(t(), binary()) :: {:ok, t()} | {:error, Error.t()}
  def feed(state, bytes) do
    if state.bytes + byte_size(bytes) <= state.max_bytes do
      consume(%{state | bytes: state.bytes + byte_size(bytes)}, bytes)
    else
      limit()
    end
  end

  @spec finish(t()) :: {:ok, binary() | Result.t()} | {:error, Error.t()}
  def finish(%{mode: :buffer} = state), do: {:ok, join(state.chunks)}

  def finish(%{mode: :sse} = state) do
    with :ok <- SSE.finish(state.parser) do
      {:ok,
       %Result{
         exit_code: state.exit_code,
         stdout: join(state.stdout),
         stderr: join(state.stderr),
         encoding: :lossy_utf8
       }}
    end
  end

  defp consume(%{mode: :buffer} = state, bytes),
    do: {:ok, %{state | chunks: [bytes | state.chunks]}}

  defp consume(%{mode: :sse} = state, bytes) do
    with {:ok, parser, events} <- SSE.feed(state.parser, bytes) do
      Enum.reduce_while(events, {:ok, %{state | parser: parser}}, &consume_event/2)
    end
  end

  defp consume_event(event, {:ok, state}) do
    case event(state, event) do
      {:ok, updated} -> {:cont, {:ok, notify(updated, event)}}
      {:error, _error} = error -> {:halt, error}
    end
  end

  defp event(state, {:exit, code}), do: {:ok, %{state | exit_code: code}}

  defp event(_state, {:error, :remote}),
    do:
      {:error,
       %Error{category: :protocol, operation: :exec_stream, evidence: :dispatch_uncertain}}

  defp event(state, {stream, data}) when stream in [:stdout, :stderr] do
    total = state.output_bytes + byte_size(data)

    if total <= state.max_output do
      {:ok, state |> Map.update!(stream, &[data | &1]) |> Map.put(:output_bytes, total)}
    else
      limit()
    end
  end

  # Synchronous delivery provides backpressure. A failing optional observer is
  # detached; it cannot replace captured output or make a remote command retry.
  defp notify(%{on_event: nil} = state, _event), do: state

  defp notify(state, event) do
    state.on_event.(event)
    state
  rescue
    _exception -> %{state | on_event: nil}
  catch
    _kind, _reason -> %{state | on_event: nil}
  end

  defp join(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp limit,
    do:
      {:error,
       %Error{category: :output_limit, operation: :transport, evidence: :dispatch_uncertain}}
end
