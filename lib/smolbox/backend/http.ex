defmodule SmolBox.Backend.HTTP do
  @moduledoc false
  @behaviour SmolBox.Backend
  alias SmolBox.{Backend, BranchClient, Client}
  alias SmolBox.Backend.{Budget, Reference}
  alias SmolBox.Terminal.Server

  def reference(%Client{} = client) do
    %Reference{
      adapter: __MODULE__,
      kind: :http,
      id: client.worker.id,
      context: client,
      budget: %Budget{
        timeout_ms: client.worker.operation_timeout_ms,
        max_request_bytes: client.worker.max_request_bytes,
        max_response_bytes: client.worker.max_response_bytes
      }
    }
  end

  @impl true
  def supports_operation?(_context, operation),
    do:
      operation not in [
        :qualify_creation,
        :inspect_creation,
        :qualify_growth,
        :qualify_capture,
        :cleanup_capture
      ] and
        Keyword.has_key?(Backend.operations(), operation)

  @impl true
  def invoke(context, operation, arguments, budget) do
    dispatch(bounded_client(context, budget), operation, arguments)
  end

  defp dispatch(client, :open_managed_terminal, [name, spec, artifact, observer]) do
    with {:ok, qualified} <- Client.terminal_preflight(client, name, spec),
         do: Server.start(qualified, name, spec, artifact, observer)
  end

  defp dispatch(client, :observe_health, [expected]) do
    client =
      bounded_client(client, %Budget{
        timeout_ms: 500,
        max_request_bytes: 4096,
        max_response_bytes: 4096
      })

    case Client.health(client) do
      {:ok, health} -> {classify(client, health, expected), health}
      _failed -> {:unavailable, nil}
    end
  end

  defp dispatch(client, :branch_source, arguments),
    do: apply(BranchClient, :source, [client | arguments])

  defp dispatch(client, :branch_absent, arguments),
    do: apply(BranchClient, :absent, [client | arguments])

  defp dispatch(client, :branch_create, arguments),
    do: apply(BranchClient, :create, [client | arguments])

  defp dispatch(client, :branch_inspect_child, arguments),
    do: apply(BranchClient, :inspect_child, [client | arguments])

  defp dispatch(client, :branch_release, arguments),
    do: apply(BranchClient, :release, [client | arguments])

  defp dispatch(client, operation, arguments), do: apply(Client, operation, [client | arguments])

  defp bounded_client(client, budget) do
    %{
      client
      | worker: %{
          client.worker
          | operation_timeout_ms: min(client.worker.operation_timeout_ms, budget.timeout_ms),
            max_request_bytes: min(client.worker.max_request_bytes, budget.max_request_bytes),
            max_response_bytes: min(client.worker.max_response_bytes, budget.max_response_bytes)
        }
    }
  end

  defp classify(_client, %{version: actual}, expected) when actual != expected, do: :incompatible
  defp classify(_client, %{total: nil}, _expected), do: :degraded

  defp classify(client, _health, _expected) do
    case Client.readiness(client) do
      :ok -> :ready
      _failed -> :degraded
    end
  end
end
