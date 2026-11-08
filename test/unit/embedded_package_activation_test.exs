defmodule SmolBox.EmbeddedPackageActivationTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Machines, ManagedMachineSpec, Runtime, TestArtifacts}

  alias SmolBox.Backend.{Assignment, Features}
  alias SmolBox.Embedded.{Config, Launch, Port, Protocol, SDKIdentity}
  alias SmolBox.Runtime.Config, as: RuntimeConfig
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defmodule OldStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :native_material_proofs)}
    end
  end

  defmodule MaterialOnlyStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :native_background_launches)}
    end
  end

  setup do
    native = Package.create(protocol_major: 2, backend: true, persistent_backend: true)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    %{native: native}
  end

  defmodule NoStreamingStore do
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(operation)(store, unquote_splicing(args)),
        do: apply(Memory, unquote(operation), [store, unquote_splicing(args)])
    end

    def capabilities(store) do
      {:ok, caps} = Memory.capabilities(store)
      {:ok, Map.delete(caps, :native_streaming_commands)}
    end
  end

  test "package policy and the Elixir feature contract agree without enabling planned features",
       %{
         native: native
       } do
    policy = "native/policy.json" |> File.read!() |> Jason.decode!()
    assert :ok = Config.validate(native)
    assert Config.protocol_major(native) == policy["port_protocol_major"]
    assert policy["sdk"] == Config.sdk_identity(native)
    assert SDKIdentity.valid?(Config.sdk_identity(native))
    assert Features.native_versions(native).material_proofs == 2

    for feature <- ~w(networking ports workloads background_exec logs streaming_exec terminals)a do
      assert Features.supports?(native, feature)
    end

    for feature <- ~w(remote_sources images
                       volumes disk_growth checkpoints exports branches)a do
      refute Features.supports?(native, feature)
    end
  end

  test "approved protocol selects the private config schema before opening a helper", %{
    native: native
  } do
    {:ok, directory} = Launch.directory()
    on_exit(fn -> Launch.cleanup(directory) end)
    assert {:ok, prepared} = Launch.prepare(native, directory)
    assert prepared.protocol_major == 2 and prepared.protocol_minor == 0
    config = prepared.config_path |> File.read!() |> Jason.decode!()
    assert config["schema"] == 2
    assert config["publish_address"] == "127.0.0.1"
    assert config["package_manifest_sha256"] == native.package_manifest_sha256
    assert Package.received(native) == []
  end

  test "reapproved mismatched SDK or relabelled legacy manifest fails before launch", %{
    native: native
  } do
    path = Path.join(native.package_path, "package.json")
    original = path |> File.read!() |> Jason.decode!()
    changed_sdk = put_in(original, ["policy", "sdk", "feature_versions", "volumes"], 1)

    for manifest <- [
          changed_sdk,
          put_in(original, ["policy", "job_limits", "work_slots"], 5),
          put_in(original, ["policy", "publish_address_default"], "0.0.0.0"),
          Map.put(original, "schema", 2),
          put_in(original, ["identity", "build_sha256"], String.duplicate("0", 64))
        ] do
      bytes = Jason.encode!(manifest)
      File.write!(path, bytes)
      config = %{native | package_manifest_sha256: Package.hash(bytes)}
      {:ok, directory} = Launch.directory()
      assert Launch.prepare(config, directory) == :error
      Launch.cleanup(directory)
      refute File.exists?(Path.join(directory, "config.json"))
    end

    assert Package.received(native) == []
  end

  test "wrong SDK handshake cannot activate even when package hashes pass", %{native: native} do
    path = Path.join(native.package_path, "fixture.json")
    metadata = path |> File.read!() |> Jason.decode!()
    metadata = put_in(metadata, ["sdk", "feature_versions", "volumes"], 1)
    File.write!(path, Jason.encode!(metadata))
    owner = start_supervised!(Supervisor.child_spec({Port, native}, restart: :temporary))
    await(fn -> Enum.any?(Package.received(native), &Map.has_key?(&1, "launch")) end)

    await(fn ->
      match?(
        {:ok, %{status: status}} when status in [:unavailable, :quarantined],
        Port.health(owner)
      )
    end)

    refute Enum.any?(Package.received(native), &(&1["type"] == "approve"))
    assert {:error, _} = Port.activate(owner, Config.domain_binding(native))
  end

  test "material-reader capability rejects public startup before native enrollment", %{
    native: native
  } do
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})
    options = options(native, store, artifacts)

    assert {:error, %{category: :unsupported_capability}} =
             RuntimeConfig.new(Keyword.put(options, :store, {OldStore, store}))

    assert Package.received(native) == []

    assert {:error, %{category: :unsupported_capability}} =
             RuntimeConfig.new(Keyword.put(options, :store, {MaterialOnlyStore, store}))

    assert Package.received(native) == []

    assert {:error, %{category: :unsupported_capability}} =
             RuntimeConfig.new(Keyword.put(options, :store, {NoStreamingStore, store}))

    assert Package.received(native) == []
  end

  test "protocol-2 approval cannot promote a legacy intent or dispatch a stripped receipt", %{
    native: native
  } do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "activation",
        id: "retained",
        profile: hd(native.profiles),
        artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      )

    legacy = %{
      native
      | package_identity: %{native.package_identity | "engine_version" => "0.1.0"},
        sdk_identity: nil
    }

    assert {:ok, old} = Assignment.new(legacy, spec, "legacy")
    assert Assignment.valid?(old)
    refute Assignment.approved?(old, native, spec)
    owner = start_supervised!(Supervisor.child_spec({Port, native}, restart: :temporary))
    await(fn -> match?({:ok, %{status: :reconciling}}, Port.health(owner)) end)
    assert :ok = Port.activate(owner, Config.domain_binding(native))
    command = Package.command(native, "echo")
    stripped = Map.update!(command, "receipt", &Map.delete(&1, "material"))
    assert {:error, _} = Port.submit(owner, stripped, native.budget, self())
    refute Enum.any?(Package.received(native), &(&1["type"] == "request"))
  end

  test "graceful stopped Runtime replacement preserves v17 authority and never replays create", %{
    native: native
  } do
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})
    options = options(native, store, artifacts)
    runtime = start_supervised!(SmolBox.child_spec(options))
    await(fn -> ready?(runtime) end)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "activation",
        id: "retained",
        profile: hd(native.profiles),
        artifact: native.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      )

    assert {:ok, handle} = Machines.create(runtime, spec)
    assert {:ok, %{state: :stopped} = created} = Machines.await(runtime, handle, 5000)
    assert created.backend_assignment.version == 2
    assert {:ok, encoded} = Codec.encode(created)
    assert String.starts_with?(encoded, "smolbox-record-v17\0")
    assert {:ok, ^created} = Codec.decode(encoded)
    assert :ok = SmolBox.drain_worker(runtime, native.id)
    stop_supervised!({Runtime, __MODULE__})
    assert :global.whereis_name({Port, node()}) == :undefined

    replacement = start_supervised!(SmolBox.child_spec(options))
    await(fn -> match?({:ok, [%{status: :draining}]}, SmolBox.workers(replacement)) end)

    await(fn ->
      match?({:ok, %{status: :ready}}, Port.health(:global.whereis_name({Port, node()})))
    end)

    assert {:ok, recovered} = Machines.inspect(replacement, handle)
    assert recovered.created_machine == created.created_machine
    assert recovered.backend_assignment == created.backend_assignment
    assert recovered.reservation == created.reservation
    assert recovered.state == :stopped
    requests = Enum.filter(Package.received(native), &(&1["type"] == "request"))
    assert Enum.count(requests, &(&1["operation"]["operation"] == "create")) == 1
    assert Enum.any?(requests, &(&1["operation"]["operation"] == "inspect"))
    assert {:ok, maintenance} = SmolBox.worker_maintenance(replacement, native.id)

    assert {:ok, %{mode: :active}} =
             SmolBox.resume_worker(replacement, native.id, maintenance.control.version)

    await(fn -> ready?(replacement) end)
    assert {:ok, [worker]} = SmolBox.workers(replacement)
    assert worker.health.protocol_version == %{major: 2, minor: 0}
    assert worker.health.engine_limits == Protocol.limits(2, 0)
    assert {:ok, latest} = Machines.inspect(replacement, handle)
    assert {:ok, _} = Machines.delete(replacement, handle, latest.version)
    assert {:ok, %{state: :deleted}} = Machines.await(replacement, handle, 5000)
    assert {:ok, %{slots: 0}} = Memory.usage(store, native.id)
  end

  defp options(native, store, artifacts),
    do: [
      name: __MODULE__,
      namespace: "activation",
      mode: :ephemeral,
      store: {Memory, store},
      artifact_store: {TestArtifacts, artifacts},
      fingerprint_key: String.duplicate("k", 32),
      workers: [native],
      lease_ms: 1000,
      poll_ms: 20
    ]

  defp ready?(runtime), do: match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime))
  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("ordinary native fixture did not settle")

  defp await(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          await(check, attempts - 1)
        )
  end
end
