defmodule SmolBox.Runtime.NativeMaterialSupportTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.Config
  alias SmolBox.Error
  alias SmolBox.Runtime.{NativeSupport, Target}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule LegacyStore do
    def capabilities(_context),
      do: {:ok, %{backend_bindings: 1, backend_recovery: 1, managed_machines: 1}}

    def bind_backend(_, _, _), do: raise("verification must not enroll")
    def backend_assignments(_, _, _, _), do: raise("verification must not inspect")
    def machine(_, _, _), do: raise("verification must not mutate")
  end

  defmodule StreamingStore do
    alias SmolBox.Runtime.NativeMaterialSupportTest.LaunchStore

    def capabilities(context) do
      {:ok, caps} = LaunchStore.capabilities(context)
      {:ok, Map.put(caps, :native_streaming_commands, 1)}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  defmodule TerminalStore do
    alias SmolBox.Runtime.NativeMaterialSupportTest.StreamingStore

    def capabilities(context) do
      {:ok, caps} = StreamingStore.capabilities(context)
      {:ok, Map.put(caps, :native_terminal_sessions, 1)}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  defmodule GrowthStore do
    alias SmolBox.Runtime.NativeMaterialSupportTest.TerminalStore

    def capabilities(context) do
      {:ok, caps} = TerminalStore.capabilities(context)
      {:ok, Map.merge(caps, %{native_disk_growth: 1, managed_disk_expansion: 1})}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  defmodule BranchStore do
    def capabilities(extra) do
      {:ok, caps} = TerminalStore.capabilities(nil)
      {:ok, Map.merge(caps, extra)}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  test "future branch descriptor requires native readers and paired store transactions before enrollment" do
    native = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    target = Target.normalize(native)
    sdk = put_in(native.sdk_identity, ["feature_versions", "branches"], 1)
    future = %{target | native_config: %{native | sdk_identity: sdk}}

    for caps <- [
          %{},
          %{managed_branches: 1},
          %{native_branches: 1},
          %{managed_branches: 1, native_branches: 2},
          %{managed_branches: 1, native_branches: 1},
          %{managed_branches: 1, native_branches: 1, native_partial_branch_collections: 2},
          %{managed_branches: 1, native_branches: 1, native_partial_branch_collections: 1},
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 2
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 2
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1,
            native_partial_branch_backings: 2
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1,
            native_partial_branch_backings: 1
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1,
            native_partial_branch_backings: 1,
            native_partial_branch_cleanups: 2
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1,
            native_partial_branch_backings: 1,
            native_partial_branch_cleanups: 1
          },
          %{
            managed_branches: 1,
            native_branches: 1,
            native_partial_branch_collections: 1,
            native_partial_branch_disposals: 1,
            native_partial_branch_retirements: 1,
            native_partial_branch_backings: 1,
            native_partial_branch_cleanups: 1,
            native_partial_branch_cleanup_resolutions: 2
          }
        ] do
      assert {:error, %Error{category: :unsupported_capability}} =
               NativeSupport.verify(%{workers: [future], store: {BranchStore, caps}})
    end

    assert :ok =
             NativeSupport.verify(%{
               workers: [future],
               store:
                 {BranchStore,
                  %{
                    managed_branches: 1,
                    native_branches: 1,
                    native_partial_branch_collections: 1,
                    native_partial_branch_disposals: 1,
                    native_partial_branch_retirements: 1,
                    native_partial_branch_backings: 1,
                    native_partial_branch_cleanups: 1,
                    native_partial_branch_cleanup_resolutions: 1
                  }}
             })

    assert :ok = NativeSupport.verify(%{workers: [target], store: {TerminalStore, nil}})
    assert Package.received(native) == []
    # The semantic future descriptor above is never a valid public configuration.
    assert {:error, _} = Config.validate(future.native_config)
  end

  test "future growth descriptor requires both the native history reader and atomic expansion store" do
    native = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    target = Target.normalize(native)
    sdk = put_in(native.sdk_identity, ["feature_versions", "disk_growth"], 1)
    future = %{target | native_config: %{native | sdk_identity: sdk}}

    assert {:error, %Error{category: :unsupported_capability}} =
             NativeSupport.verify(%{workers: [future], store: {TerminalStore, nil}})

    assert :ok = NativeSupport.verify(%{workers: [future], store: {GrowthStore, nil}})
    assert :ok = NativeSupport.verify(%{workers: [target], store: {TerminalStore, nil}})
    assert Package.received(native) == []
  end

  test "terminal descriptor requires its native reader marker before any enrollment" do
    native = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    target = Target.normalize(native)
    sdk = put_in(native.sdk_identity, ["feature_versions", "terminals"], 1)
    future = %{target | native_config: %{native | sdk_identity: sdk}}

    assert {:error, %Error{category: :unsupported_capability}} =
             NativeSupport.verify(%{workers: [future], store: {StreamingStore, nil}})

    assert :ok = NativeSupport.verify(%{workers: [future], store: {TerminalStore, nil}})

    older = %{
      target
      | native_config: %{
          native
          | sdk_identity: update_in(sdk, ["feature_versions"], &Map.delete(&1, "terminals"))
        }
    }

    assert :ok = NativeSupport.verify(%{workers: [older], store: {StreamingStore, nil}})
    assert Package.received(native) == []
  end

  defmodule MaterialStore do
    def capabilities(context) do
      {:ok, old} = LegacyStore.capabilities(context)
      {:ok, Map.put(old, :native_material_proofs, 2)}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  defmodule LaunchStore do
    def capabilities(context) do
      {:ok, caps} = MaterialStore.capabilities(context)
      {:ok, Map.put(caps, :native_background_launches, 1)}
    end

    defdelegate bind_backend(a, b, c), to: LegacyStore
    defdelegate backend_assignments(a, b, c, d), to: LegacyStore
    defdelegate machine(a, b, c), to: LegacyStore
  end

  test "background descriptor requires explicit reader support before enrollment" do
    native = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    target = Target.normalize(native)

    assert {:error, %Error{category: :unsupported_capability, operation: :runtime}} =
             NativeSupport.verify(%{workers: [target], store: {MaterialStore, nil}})

    assert {:error, %Error{category: :unsupported_capability, operation: :runtime}} =
             NativeSupport.verify(%{workers: [target], store: {LaunchStore, nil}})

    assert :ok = NativeSupport.verify(%{workers: [target], store: {TerminalStore, nil}})
    assert Package.received(native) == []
    sdk = native.sdk_identity

    old_sdk = %{
      sdk
      | "feature_versions" =>
          Map.drop(sdk["feature_versions"], ~w(background_exec streaming_exec terminals))
    }

    old = Package.create(protocol_major: 2, sdk_identity: old_sdk)
    on_exit(fn -> File.rm_rf!(old.package_path) end)

    assert :ok =
             NativeSupport.verify(%{
               workers: [Target.normalize(old)],
               store: {MaterialStore, nil}
             })

    assert Package.received(old) == []
  end

  test "protocol-2 negotiation requires explicit material-reader capability before enrollment" do
    config = Package.create()
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    legacy = Target.normalize(config)
    assert :ok = NativeSupport.verify(%{workers: [legacy], store: {LegacyStore, nil}})

    future_config = %{
      config
      | package_identity: %{config.package_identity | "engine_version" => "0.2.0"}
    }

    future = %{legacy | native_config: future_config}

    assert {:error, %Error{category: :unsupported_capability, operation: :runtime}} =
             NativeSupport.verify(%{workers: [future], store: {LegacyStore, nil}})

    assert :ok = NativeSupport.verify(%{workers: [future], store: {TerminalStore, nil}})
  end

  test "older protocol-2 descriptor needs no streaming reader upgrade" do
    current = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(current.package_path) end)
    sdk = current.sdk_identity
    sdk = update_in(sdk, ["feature_versions"], &Map.drop(&1, ~w(streaming_exec terminals)))
    native = Package.create(protocol_major: 2, sdk_identity: sdk)
    on_exit(fn -> File.rm_rf!(native.package_path) end)

    assert :ok =
             NativeSupport.verify(%{
               workers: [Target.normalize(native)],
               store: {LaunchStore, nil}
             })

    assert Package.received(native) == []
  end
end
