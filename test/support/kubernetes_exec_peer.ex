defmodule SmolBox.KubernetesExecPeer do
  @moduledoc false
  @behaviour WebSock

  defmodule Proof do
    @moduledoc false
    def check(_, _, _), do: {:error, :unused}
    def cleanup(_, _, _, _), do: {:error, :unused}

    def capture(_, _, _, observation),
      do: {:ok, %{observation | observed_at_ms: System.system_time(:millisecond)}}
  end

  @impl true
  def init(options) do
    send(options.owner, {:exec_socket, self()})
    {:ok, Map.merge(options, %{input: <<>>, produced: false})}
  end

  @impl true
  def handle_in({<<0, bytes::binary>>, [opcode: :binary]}, state) do
    input = state.input <> bytes
    next = %{state | input: input}

    case input do
      <<"SBK1", size::32, rest::binary>> when byte_size(rest) == size and not state.produced ->
        send(state.owner, {:exec_request, self(), Jason.decode!(rest)})
        next = %{next | produced: true}

        if state.mode == :hold do
          {:ok, next}
        else
          send(self(), :finish)
          {:push, state.frames, next}
        end

      _ ->
        {:ok, next}
    end
  end

  def handle_in({<<255, 0>>, _}, state) do
    send(state.owner, :unexpected_eof)
    {:stop, :normal, state}
  end

  def handle_in(_, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(:finish, state), do: {:stop, :normal, 1000, state}
  def handle_info({:frames, frames}, state), do: {:push, frames, state}
  @impl true
  def terminate(_, state), do: send(state.owner, {:exec_socket_closed, self()})
end
