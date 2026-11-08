defmodule SmolBox.Runtime.NativeSupport do
  @moduledoc false
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.Config
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

    with {:ok, %{backend_bindings: 1, backend_recovery: 1, managed_machines: 1} = supported} <-
           Session.store(config, :capabilities, []),
         true <- material_support?(config, supported),
         true <- background_support?(config, supported),
         true <- streaming_support?(config, supported),
         true <- terminal_support?(config, supported),
         true <-
           Enum.all?(required, fn {name, arity} -> function_exported?(adapter, name, arity) end),
         do: :ok,
         else: (_ -> Session.error(:unsupported_capability, :runtime))
  end

  defp material_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.protocol_major(target.native_config) do
          1 -> true
          2 -> supported[:native_material_proofs] == 2
          _unsupported -> false
        end
      end)

  defp background_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"background_exec" => 1}} ->
            supported[:native_background_launches] == 1

          _ ->
            true
        end
      end)

  defp streaming_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"streaming_exec" => 1}} ->
            supported[:native_streaming_commands] == 1

          _ ->
            true
        end
      end)

  defp terminal_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"terminals" => 1}} ->
            supported[:native_terminal_sessions] == 1

          _ ->
            true
        end
      end)
end
