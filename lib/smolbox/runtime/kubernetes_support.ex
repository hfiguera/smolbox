defmodule SmolBox.Runtime.KubernetesSupport do
  @moduledoc false
  alias SmolBox.Kubernetes.{Assignment, Config, LabController}
  alias SmolBox.Runtime.{Session, Target}

  def targets(config), do: Enum.filter(config.workers, &match?(%{kind: :kubernetes}, &1))

  def verify(config) do
    case targets(config) do
      [] -> :ok
      [_] -> capabilities(config)
      _ -> Session.error(:unsupported_capability, :runtime)
    end
  end

  def acquire(config) do
    Enum.reduce_while(targets(config), {:ok, config}, fn target, {:ok, current} ->
      case acquire_target(current, target) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  def replace(config, target, context) do
    worker = Target.normalize(%{target.kubernetes_config | controller_guard: context})
    %{config | workers: Enum.map(config.workers, &if(&1.id == worker.id, do: worker, else: &1))}
  end

  defp acquire_target(config, %{kubernetes_config: %{controller_guard: nil}}), do: {:ok, config}

  defp acquire_target(config, target) do
    kube = target.kubernetes_config

    with {:ok, context} <-
           LabController.acquire(
             Config.binding(kube),
             config.owner,
             kube.budget,
             kube.controller_guard
           ),
         do: {:ok, replace(config, target, context)}
  end

  def recovery_owner(config, %{backend_assignment: %Assignment{} = assignment} = record) do
    target = Enum.find(targets(config), &(&1.id == record.worker_id))

    case target && target.kubernetes_config.controller_guard do
      nil ->
        if record.claim_owner == config.owner,
          do: :ok,
          else: Session.error(:unsupported_capability, :reconcile)

      context ->
        if context.owner == config.owner and record.claim_owner in context.known_owners,
          do: LabController.check(assignment.binding, target.kubernetes_config.budget, context),
          else: Session.error(:identity_conflict, :reconcile)
    end
  end

  def recovery_owner(_config, _record), do: :ok

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
