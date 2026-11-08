defmodule SmolBox.Runtime.NativeSupport do
  @moduledoc false
  alias SmolBox.Backend.Binding
  alias SmolBox.Runtime.{Session, Target}

  def targets(config), do: Enum.filter(config.workers, &match?(%{kind: :embedded}, &1))

  def verify(config) do
    case targets(config) do
      [] -> :ok
      [_target] -> capabilities(config)
      _multiple_domains -> Session.error(:unsupported_capability, :runtime)
    end
  end

  def enroll(config) do
    with :ok <- verify(config) do
      Enum.reduce_while(targets(config), :ok, &enroll_target(config, &1, &2))
    end
  end

  defp enroll_target(config, target, :ok) do
    binding = struct!(Binding, target.domain_binding)

    case Session.store(config, :bind_backend, [Target.id(target), binding]) do
      {:ok, ^binding} -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
      _invalid -> {:halt, Session.error(:store, :runtime)}
    end
  end

  defp capabilities(%{store: {adapter, _context}} = config) do
    required = [bind_backend: 3, backend_assignments: 4, machine: 3]

    with {:ok, %{backend_bindings: 1, backend_recovery: 1, managed_machines: 1}} <-
           Session.store(config, :capabilities, []),
         true <-
           Enum.all?(required, fn {name, arity} -> function_exported?(adapter, name, arity) end),
         do: :ok,
         else: (_ -> Session.error(:unsupported_capability, :runtime))
  end
end
