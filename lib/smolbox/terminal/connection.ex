defmodule SmolBox.Terminal.Connection do
  @moduledoc false
  alias SmolBox.{Error, Worker}
  alias SmolBox.Terminal.Connection.HTTP

  @enforce_keys [:adapter, :state, :input_left]
  @derive {Inspect, only: [:adapter]}
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{adapter: module(), state: term(), input_left: non_neg_integer()}

  def open(%Worker{} = worker, name, spec), do: open({HTTP, worker}, name, spec)

  # The backend selects this internal source after approval. Client.open_terminal
  # remains HTTP-only; callers cannot replace its transport through this path.
  def open({adapter, context}, name, spec) do
    with {:ok, state, budget} when is_integer(budget) and budget >= 0 <-
           adapter.open(context, name, spec),
         do: {:ok, %__MODULE__{adapter: adapter, state: state, input_left: budget}}
  end

  def send(%__MODULE__{} = connection, command) do
    cost = input_cost(connection, command)

    if is_integer(cost) and cost >= 0 and cost <= connection.input_left do
      case connection.adapter.send(connection.state, command) do
        {:ok, state} ->
          {:ok, %{connection | state: state, input_left: connection.input_left - cost}}

        error ->
          error
      end
    else
      {:error, %Error{category: :output_limit, operation: :terminal, evidence: :unknown}}
    end
  end

  defp input_cost(connection, command) when elem(command, 0) in [:input, :resize],
    do: connection.adapter.input_cost(connection.state, command)

  defp input_cost(_connection, _control), do: 0

  def poll(%__MODULE__{} = connection) do
    case connection.adapter.poll(connection.state) do
      {:ok, state, events} -> {:ok, %{connection | state: state}, events}
      error -> error
    end
  end

  def acknowledge(%__MODULE__{} = connection, bytes) do
    case connection.adapter.acknowledge(connection.state, bytes) do
      {:ok, state} -> {:ok, %{connection | state: state}}
      error -> error
    end
  end

  def close(%__MODULE__{} = connection), do: connection.adapter.close(connection.state)

  def handle_message(%__MODULE__{} = connection, message) do
    if function_exported?(connection.adapter, :handle_message, 2) do
      case connection.adapter.handle_message(connection.state, message) do
        {:ok, state, events} -> {:ok, %{connection | state: state}, events}
        other -> other
      end
    else
      :ignore
    end
  end
end
