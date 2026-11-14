defmodule SmolBox.Runtime.KubernetesSupport do
  @moduledoc false
  alias SmolBox.Kubernetes.Config
  alias SmolBox.Runtime.Session

  def targets(config), do: Enum.filter(config.workers, &match?(%{kind: :kubernetes}, &1))

  def verify(config) do
    case targets(config) do
      [] -> :ok
      [_] -> capabilities(config)
      _ -> Session.error(:unsupported_capability, :runtime)
    end
  end

  def enroll(config) do
    with :ok <- verify(config) do
      Enum.reduce_while(targets(config), :ok, &enroll_target(config, &1, &2))
    end
  end

  defp enroll_target(config, target, :ok) do
    binding = Config.binding(target.kubernetes_config)

    case Session.store(config, :bind_backend, [target.id, binding]) do
      {:ok, ^binding} -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
      _ -> {:halt, Session.error(:store, :runtime)}
    end
  end

  defp capabilities(%{store: {adapter, _}} = config) do
    with {:ok, %{kubernetes_backend: 1, backend_bindings: 1, backend_recovery: 1}} <-
           Session.store(config, :capabilities, []),
         true <-
           Enum.all?([bind_backend: 3, backend_assignments: 4], fn {name, arity} ->
             function_exported?(adapter, name, arity)
           end),
         do: :ok,
         else: (_ -> Session.error(:unsupported_capability, :runtime))
  end

  defp capabilities(_), do: Session.error(:unsupported_capability, :runtime)
end
