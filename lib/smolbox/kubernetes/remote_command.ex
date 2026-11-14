defmodule SmolBox.Kubernetes.RemoteCommand do
  @moduledoc false
  alias SmolBox.Kubernetes.{ExitStatus, GuestHelper}
  alias SmolBox.Result

  def new(max),
    do: %{
      stdout: [],
      stderr: [],
      pending_stderr: [],
      bytes: 0,
      max: max,
      ack: <<>>,
      status: <<>>,
      exit: nil,
      streams_closed: [],
      closed: false,
      error: nil
    }

  def feed(%{closed: true} = state, _frame), do: fail(state, :protocol)

  def feed(state, {:binary, <<255, channel>>}) when channel in 0..3 do
    if channel in state.streams_closed,
      do: fail(state, :protocol),
      else: {:ok, %{state | streams_closed: [channel | state.streams_closed]}, []}
  end

  def feed(state, {:binary, <<channel, data::binary>>}) when channel in 1..3 do
    if channel in state.streams_closed,
      do: fail(state, :protocol),
      else: channel(state, channel, data)
  end

  def feed(state, {:ping, data}), do: {:ok, state, [{:pong, data}]}
  def feed(state, {:pong, _}), do: {:ok, state, []}

  def feed(state, {:close, 1000, _reason}),
    do: {:ok, %{state | closed: true}, []}

  def feed(state, _), do: fail(state, :protocol)

  defp channel(state, 1, data) do
    needed = byte_size(GuestHelper.ack()) - byte_size(state.ack)
    count = min(needed, byte_size(data))
    <<part::binary-size(^count), rest::binary>> = data
    ack = state.ack <> part

    if binary_part(GuestHelper.ack(), 0, byte_size(ack)) == ack do
      release_stderr(output(%{state | ack: ack}, :stdout, rest))
    else
      fail(state, :protocol)
    end
  end

  defp channel(state, 2, data) do
    case output(state, :stderr, data) do
      {:ok, next, events} when state.ack != <<"SBK1", 0::32>> ->
        {:ok, %{next | pending_stderr: Enum.reverse(events, next.pending_stderr)}, []}

      {:error, category, next, _events} when state.ack != <<"SBK1", 0::32>> ->
        {:error, category, next, []}

      other ->
        other
    end
  end

  defp channel(state, 3, data) do
    cond do
      byte_size(state.status) + byte_size(data) > 8192 ->
        fail(state, :output_limit)

      state.exit != nil and not Regex.match?(~r/\A[ \t\r\n]*\z/, data) ->
        fail(state, :protocol)

      true ->
        status = state.status <> data

        exit =
          case ExitStatus.decode(status) do
            {:ok, value} -> value
            :error -> nil
          end

        {:ok, %{state | status: status, exit: exit}, []}
    end
  end

  defp release_stderr({:ok, %{ack: <<"SBK1", 0::32>>} = next, events}),
    do: {:ok, %{next | pending_stderr: []}, events ++ Enum.reverse(next.pending_stderr)}

  defp release_stderr(other), do: other

  defp output(state, _stream, <<>>), do: {:ok, state, []}

  defp output(state, stream, data) do
    count = min(byte_size(data), state.max - state.bytes)
    kept = binary_part(data, 0, count)
    next = state |> Map.update!(stream, &[kept | &1]) |> Map.put(:bytes, state.bytes + count)
    events = if kept == "", do: [], else: [{stream, kept}]

    if count == byte_size(data),
      do: {:ok, next, events},
      else: {:error, :output_limit, %{next | error: :output_limit}, events}
  end

  def result(state, category \\ nil) do
    error = category || state.error
    qualified = qualified?(state)

    cond do
      qualified and error == nil and state.closed -> {:ok, result_value(state, false)}
      qualified -> {:error, error || :protocol, result_value(state, true)}
      true -> {:error, error || :protocol}
    end
  end

  defp qualified?(state), do: state.ack == GuestHelper.ack() and is_integer(state.exit)

  defp result_value(state, truncated),
    do: %Result{
      exit_code: state.exit,
      encoding: :bytes,
      truncated: truncated,
      stdout: state.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: state.stderr |> Enum.reverse() |> IO.iodata_to_binary()
    }

  defp fail(state, category), do: {:error, category, %{state | error: category}, []}
end
