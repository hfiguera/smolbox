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
         true <- growth_support?(config, supported),
         true <- source_support?(config, supported),
         true <- checkpoint_source_support?(config, supported),
         true <- export_support?(config, supported),
         true <- branch_support?(config, supported),
         true <- volume_support?(config, supported, adapter),
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

  defp growth_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"disk_growth" => 1}} ->
            supported[:native_disk_growth] == 1 and supported[:managed_disk_expansion] == 1

          _ ->
            true
        end
      end)

  # This marker covers all native branch readers and paired resource writers,
  # including v31 explicit release. Existing HTTP branch support is insufficient.
  # Stores must not advertise it until the complete native lifecycle is supported.
  defp branch_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"branches" => 1}} ->
            supported[:native_branches] == 1 and supported[:managed_branches] == 1

          _ ->
            true
        end
      end)

  defp source_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        features = Config.sdk_identity(target.native_config)

        required =
          match?(%{"feature_versions" => %{"remote_sources" => 1}}, features) or
            match?(%{"feature_versions" => %{"images" => 1}}, features)

        not required or
          (supported[:native_sources] == 1 and supported[:registry_sources] == 1 and
             (not match?(%{"feature_versions" => %{"images" => 1}}, features) or
                supported[:managed_images] == 1))
      end)

  defp checkpoint_source_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"checkpoints" => 1}} ->
            supported[:native_checkpoint_sources] == 1 and supported[:native_checkpointable] == 1 and
              supported[:native_capture_histories] == 1 and
              supported[:native_capture_resolutions] == 1 and
              supported[:native_capture_cleanup] == 1 and
              supported[:native_capture_abort_sources] == 1

          _ ->
            true
        end
      end)

  defp export_support?(config, supported),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"exports" => 1}} ->
            supported[:native_export_histories] == 1 and supported[:managed_exports] == 1

          _ ->
            true
        end
      end)

  defp volume_support?(config, supported, adapter),
    do:
      Enum.all?(targets(config), fn target ->
        case Config.sdk_identity(target.native_config) do
          %{"feature_versions" => %{"volumes" => 1}} ->
            target.native_config.platform == :linux and supported[:native_volumes] == 1 and
              supported[:local_volumes] == 1 and volume_callbacks?(adapter)

          _ ->
            true
        end
      end)

  defp volume_callbacks?(adapter),
    do:
      Enum.all?([volume_accept: 3, volume_fetch: 2, volume_list: 4, volume_change: 5], fn {name,
                                                                                           arity} ->
        function_exported?(adapter, name, arity)
      end)
end
