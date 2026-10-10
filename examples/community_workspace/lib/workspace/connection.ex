defmodule Workspace.Connection do
  @moduledoc "Starts durable management only after explicit configuration and migrations."
  use GenServer
  alias Ecto.Adapters.SQL
  alias SmolBox.DurableHost.Store
  alias Workspace.{Repo, Settings}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def context, do: GenServer.call(__MODULE__, :context)
  def status, do: GenServer.call(__MODULE__, :status)
  def refresh, do: send(__MODULE__, :connect)

  def format_status(status),
    do: Map.update(status, :state, nil, &Map.put(&1, :context, :redacted))

  def init(_) do
    if Application.get_env(:community_workspace, :connect_runtime, true),
      do: send(self(), :connect)

    {:ok, %{context: nil, status: :setup_required}}
  end

  def handle_call(:context, _from, %{context: nil} = state),
    do: {:reply, {:error, state.status}, state}

  def handle_call(:context, _from, state), do: {:reply, {:ok, state.context}, state}
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_info(:connect, state) do
    next =
      case connect(state.context) do
        {:ok, context} -> %{context: context, status: :ready}
        {:error, reason} -> %{state | status: reason}
      end

    Process.send_after(self(), :connect, 5000)
    {:noreply, next}
  end

  defp connect(nil) do
    with {:ok, settings} <- Settings.load(),
         :ok <- database_ready(),
         {:ok, context} <- Settings.build(settings),
         {:ok, _} <- Store.capabilities(context.store),
         :ok <- ensure_runtime(context) do
      {:ok, context}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :store_unavailable}
    end
  end

  defp connect(context) do
    with :ok <- database_ready(),
         {:ok, _} <- Store.capabilities(context.store),
         {:ok, %{version: version}} <- SmolBox.Client.health(health_client(context.client)),
         true <- version == Settings.runtime_version(context.settings),
         :ok <- ensure_runtime(context) do
      {:ok, context}
    else
      _ -> {:error, :worker_or_store_unavailable}
    end
  end

  defp ensure_runtime(context) do
    if Process.whereis(Settings.runtime()) do
      :ok
    else
      case DynamicSupervisor.start_child(Workspace.Runtimes, {SmolBox.Runtime, context.options}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _ -> {:error, :runtime_unavailable}
      end
    end
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  defp health_client(client),
    do: %{
      client
      | worker: %{client.worker | operation_timeout_ms: 1000, receive_timeout_ms: 1000}
    }

  def database_ready do
    case SQL.query(
           Repo,
           "SELECT h.partition FROM workspace_homes h JOIN workspace_actions a ON false LIMIT 0",
           [],
           log: false,
           timeout: 1000
         ) do
      {:ok, _} -> :ok
      _ -> {:error, :database_or_migrations_required}
    end
  rescue
    _ -> {:error, :database_or_migrations_required}
  catch
    :exit, _ -> {:error, :database_or_migrations_required}
  end
end
