defmodule SmolBox.Terminal.Wire do
  @moduledoc false
  alias SmolBox.Terminal.Result

  defdelegate new(websocket, max), to: SmolBox.WebSocket.Wire
  defdelegate feed(state, bytes), to: SmolBox.WebSocket.Wire

  def event({:binary, bytes}), do: {:ok, {:output, bytes}}

  def event({:text, bytes}) when byte_size(bytes) <= 128 do
    case Jason.decode(bytes) do
      {:ok, %{"type" => "exit", "code" => code} = value} when map_size(value) == 2 ->
        result = %Result{exit_code: code}
        if Result.valid?(result), do: {:ok, {:exit, result}}, else: {:error, :unknown}

      _invalid ->
        {:error, :protocol}
    end
  end

  def event({:ping, data}), do: {:ok, {:pong, data}}
  def event({:pong, _data}), do: {:ok, :ignore}
  def event({:close, _code, _reason}), do: {:error, :unknown}
  def event(_invalid), do: {:error, :protocol}
end
