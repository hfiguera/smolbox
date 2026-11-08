defmodule SmolBox.NativeVolumeRecoveryTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Binding, Budget, Embedded, EmbeddedContext, EmbeddedVolume}
  alias SmolBox.Embedded.{Config, JSON, VolumeAuthority}
  alias SmolBox.{Error, Volume, VolumePolicy}
  alias SmolBox.Runtime.{NativeSupport, NativeVolumeRecovery, Target}
  alias SmolBox.Store.{Memory, VolumeContract, VolumeOps}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule IncompleteVolumeStore do
    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.put(capabilities, :native_volumes, 1)}
    end

    def bind_backend(_, _, _), do: raise("reader verification must not enroll")
    def backend_assignments(_, _, _, _), do: raise("reader verification must not recover")
    def machine(_, _, _), do: raise("reader verification must not mutate")
    def volume_accept(_, _, _), do: raise("reader verification must not allocate")
    def volume_fetch(_, _), do: raise("reader verification must not read")
    def volume_list(_, _, _, _), do: raise("reader verification must not list")
  end

  defmodule LegacyVolumeStore do
    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, :native_volumes)}
    end

    defdelegate bind_backend(s, w, b), to: Memory
    defdelegate backend_assignments(s, w, c, l), to: Memory
    defdelegate machine(s, a, r), to: Memory
    defdelegate volume_accept(s, v, c), to: Memory
    defdelegate volume_fetch(s, k), to: Memory
    defdelegate volume_list(s, n, c, l), to: Memory
    defdelegate volume_change(s, k, v, a, n), to: Memory
  end

  defp fixture do
    {:ok, fixture} =
      File.read!("native/smolbox-protocol/fixtures/volume-authority.json") |> JSON.decode()

    fixture
  end

  defp record do
    {:ok, policy} = VolumePolicy.new("local", "/srv/smolvm/volumes")

    %{
      VolumeContract.record()
      | policy: policy,
        size_gb: 4,
        worker_volume_id: fixture()["request"]["intent"]["worker_volume_id"],
        native_authority: %VolumeAuthority{
          binding: %Binding{
            kind: :embedded,
            target_id: "worker",
            generation: String.duplicate("b", 32)
          }
        }
    }
  end

  defp ready do
    {:ok, volume, _} =
      VolumeOps.change(record(), 1, {:complete_native, fixture()["outcome"]}, 1001)

    volume
  end

  defp budget,
    do: %Budget{timeout_ms: 100_000_000, max_request_bytes: 65_536, max_response_bytes: 65_536}

  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}
  defp status(status), do: %{"result" => "volume", "volume" => %{"status" => status}}

  test "scoped volume requests bind saved intent and reduce finite budgets" do
    v = record()

    assert {:ok, request, constrained} =
             EmbeddedVolume.request(v, %{"action" => "provision"}, budget())

    assert request["request"] == fixture()["request"]
    assert constrained.timeout_ms == 86_400_000
    assert constrained.max_response_bytes == 16_384

    assert {:ok, _, observation_budget} =
             EmbeddedVolume.request(v, %{"action" => "inspect_provision"}, budget())

    assert observation_budget.timeout_ms == 30_000
    assert {:error, _} = EmbeddedVolume.request(v, %{"action" => "delete"}, budget())

    assert {:error, _} =
             EmbeddedVolume.request(%{v | policy: nil}, %{"action" => "provision"}, budget())

    assert {:error, _} =
             EmbeddedVolume.request(VolumeContract.record(), %{"action" => "provision"}, budget())

    assert {:error, _} =
             EmbeddedVolume.request(v, %{"action" => "provision", "root" => "/caller"}, budget())

    {:ok, deleting, _} = VolumeOps.change(ready(), 2, :delete, 1002)

    assert {:ok, _, _} =
             EmbeddedVolume.request(
               deleting,
               %{"action" => "resolve_deletion", "quiesced" => true},
               budget()
             )

    assert {:error, _} =
             EmbeddedVolume.request(
               deleting,
               %{"action" => "resolve_deletion", "quiesced" => false},
               budget()
             )
  end

  test "typed decoder rejects crossed roots, output and partial observation while preserving dispatch errors" do
    v = record()
    {:ok, request, _} = EmbeddedVolume.request(v, %{"action" => "provision"}, budget())
    outcome = fixture()["outcome"]
    assert {:ok, ^outcome} = EmbeddedVolume.decode(v, request, {:ok, outcome, empty(), nil})
    crossed = put_in(outcome, ~w(volume proof backing policy root), "/other/volumes")

    assert {:error, %{evidence: :dispatch_uncertain}} =
             EmbeddedVolume.decode(v, request, {:ok, crossed, empty(), nil})

    assert {:error, _} =
             EmbeddedVolume.decode(v, request, {:ok, outcome, %{empty() | stdout: "bad"}, nil})

    assert {:error, _} =
             EmbeddedVolume.decode(
               v,
               request,
               {:ok, outcome, empty(), %Error{category: :expired, operation: :embedded}}
             )

    error = %{"result" => "error", "code" => "ownership", "dispatch" => "not_dispatched"}

    assert {:error,
            %{category: :identity_conflict, operation: :volume, evidence: :not_dispatched}} =
             EmbeddedVolume.decode(v, request, {:ok, error, empty(), nil})
  end

  test "ready recovery requires exact committed proof and owner enrollment" do
    v = ready()

    target = %{
      id: "worker",
      volume_policy: v.policy,
      domain_binding: Map.from_struct(v.native_authority.binding)
    }

    assert NativeVolumeRecovery.bound?(v, target)

    refute NativeVolumeRecovery.bound?(v, %{
             target
             | domain_binding: %{target.domain_binding | generation: String.duplicate("f", 32)}
           })

    assert NativeVolumeRecovery.observation_valid?(v, fixture()["outcome"])
    refute NativeVolumeRecovery.observation_valid?(v, status("absent"))
    refute NativeVolumeRecovery.observation_valid?(v, status("unverified"))
    changed = put_in(fixture()["outcome"], ~w(volume proof backing inode), 7)
    refute NativeVolumeRecovery.observation_valid?(v, changed)
  end

  test "unready recovery never adopts proof and marks interrupted intent unknown with full capacity" do
    store = start_supervised!(Memory)
    v = record()
    {:ok, _} = Memory.bind_backend(store, v.worker_id, v.native_authority.binding)
    {:ok, _, :inserted} = Memory.volume_accept(store, v, %{disk_gb: 4})
    config = %{store: {Memory, store}, clock: SmolBox.Runtime.Clock}

    for outcome <- [fixture()["outcome"], status("absent"), status("unverified")],
        do: assert(NativeVolumeRecovery.observation_valid?(v, outcome))

    assert :ok = NativeVolumeRecovery.persist(config, v)
    assert {:ok, unknown} = Memory.volume_fetch(store, Volume.key(v))
    assert unknown.state == :unknown
    assert unknown.native_authority == v.native_authority
    assert unknown.native_authority.provision == nil
    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, v.worker_id)
    assert :ok = NativeVolumeRecovery.persist(config, unknown)
    assert {:ok, ^unknown} = Memory.volume_fetch(store, Volume.key(v))
    assert {:error, %{category: :stale_version}} = NativeVolumeRecovery.persist(config, v)
  end

  test "tombstone recovery requires matching delete or abort operation proof" do
    v = ready()
    {:ok, deleting, _} = VolumeOps.change(v, v.version, :delete, 1002)

    deletion = %{
      "result" => "volume",
      "volume" => %{
        "status" => "deleted",
        "proof" => %{
          "schema" => 1,
          "operation_id" => String.duplicate("d", 32),
          "provision" => v.native_authority.provision
        }
      }
    }

    {:ok, deleted, _} =
      VolumeOps.change(deleting, deleting.version, {:complete_native, deletion}, 1003)

    assert NativeVolumeRecovery.action(deleted) == %{"action" => "inspect_deletion"}
    assert NativeVolumeRecovery.observation_valid?(deleted, deletion)
    refute NativeVolumeRecovery.observation_valid?(deleted, status("unverified"))

    refute NativeVolumeRecovery.observation_valid?(
             deleted,
             put_in(deletion, ~w(volume proof operation_id), String.duplicate("e", 32))
           )

    {:ok, resolving, _} = VolumeOps.change(record(), 1, :resolve_delete, 1001)

    abort = %{
      "result" => "volume",
      "volume" => %{
        "status" => "aborted",
        "proof" =>
          Map.put(
            fixture()["outcome"]["volume"]["proof"],
            "operation_id",
            String.duplicate("d", 32)
          )
      }
    }

    {:ok, aborted, _} =
      VolumeOps.change(resolving, resolving.version, {:complete_native, abort}, 1002)

    assert NativeVolumeRecovery.action(aborted) == %{"action" => "inspect_abort"}
    assert NativeVolumeRecovery.observation_valid?(aborted, abort)
  end

  test "current package rejects volume scoping and public dispatch without enabling the future descriptor" do
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    {:ok, context} = EmbeddedContext.new(config, self())
    assert {:error, _} = EmbeddedContext.assign(context, record())
    refute EmbeddedContext.volume_scoped?(%{context | volume: record()})
    refute EmbeddedContext.scoped?(%{context | volume: record()})
    refute Embedded.supports_operation?(context, :provision_volume)
    refute Embedded.supports_operation?(context, :delete_volume)

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedVolume.run(
               %{context | volume: record()},
               %{"action" => "provision"},
               budget()
             )
  end

  test "native volume readers require both the marker and every callback before enrollment" do
    store = start_supervised!(Memory)
    config = Package.create(protocol_major: 2)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    sdk = put_in(Config.sdk_identity(config)["feature_versions"]["volumes"], 1)
    config = %{config | sdk_identity: sdk, platform: :linux}
    target = %Target{kind: :embedded, native_config: config}
    assert {:error, _} = Config.validate(config)

    assert :ok = NativeSupport.verify(%{workers: [target], store: {Memory, store}})

    assert {:error, %{category: :unsupported_capability}} =
             NativeSupport.verify(%{workers: [target], store: {LegacyVolumeStore, store}})

    assert {:error, %{category: :unsupported_capability}} =
             NativeSupport.verify(%{workers: [target], store: {IncompleteVolumeStore, store}})

    assert {:ok, caps} = Memory.capabilities(store)
    assert caps.native_volumes == 1
    assert {:ok, [], nil} = Memory.backend_assignments(store, "worker", nil, 10)
  end
end
