defmodule SmolBox.NativeVolumeRuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.EmbeddedVolume
  alias SmolBox.Embedded.{Config, Launch, SDKIdentity}
  alias SmolBox.Runtime.{NativeAuthority, NativeVolumeRecovery, Target}
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Command,
    ExecutionSpec,
    Machines,
    ManagedMachineSpec,
    Runtime,
    TestArtifacts,
    VolumeMount,
    VolumePolicy,
    Volumes
  }

  setup context do
    sdk = SDKIdentity.implemented("1.22.0", "9f446ae00219148ca4a703914f44a8e2fab11655")
    sdk = put_in(sdk["feature_versions"]["volumes"], 1)
    {:ok, policy} = VolumePolicy.new("local", "/srv/smolvm/volumes")

    native =
      Package.create(
        protocol_major: 2,
        platform: :linux,
        backend: true,
        persistent_backend: true,
        sdk_identity: sdk,
        volume_policy: policy,
        volume_mode: context[:volume_mode],
        volume_delay_ms: context[:volume_delay_ms],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 10}
      )

    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})

    options = [
      name: __MODULE__,
      namespace: "mounted",
      mode: :ephemeral,
      store: {Memory, store},
      artifact_store: {TestArtifacts, artifacts},
      fingerprint_key: String.duplicate("k", 32),
      workers: [native],
      lease_ms: 1000,
      poll_ms: 20
    ]

    %{native: native, store: store, options: options}
  end

  defp start_runtime(context) do
    runtime = start_supervised!(SmolBox.child_spec(context.options))

    await(
      fn -> ready?(runtime, context.native.id) end,
      500,
      fn ->
        diagnostics(runtime, context)
      end
    )

    runtime
  end

  defp ready?(runtime, id),
    do:
      match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) and
        not Map.has_key?(:sys.get_state(Runtime.coordinator(runtime)).native_holders, id)

  defp create_volume(runtime, native) do
    Volumes.create(runtime, scope: "mounted", id: "data", worker_id: native.id, size_gb: 4)
  end

  defp machine_spec(native, id) do
    {:ok, mount} = VolumeMount.new("data", "/mnt/volumes/data", readonly: true)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "mounted",
        id: id,
        artifact: hd(native.artifacts) |> Map.take(~w(id sha256 architecture)),
        profile: hd(native.profiles),
        volumes: [mount]
      )

    spec
  end

  defp volume_requests(native, action, volume_id \\ nil) do
    Package.received(native)
    |> Enum.filter(
      &(get_in(&1, ["operation", "operation"]) == "volume" and
          get_in(&1, ["operation", "request", "action", "action"]) == action and
          (volume_id == nil or
             get_in(&1, ["operation", "request", "intent", "worker_volume_id"]) == volume_id))
    )
  end

  test "x86_64 Port mount budget rejects before qualification and attachment", context do
    runtime = start_runtime(context)
    spec = machine_spec(context.native, "over-budget")

    mounts =
      for id <- ~w(first second third) do
        assert {:ok, key} =
                 Volumes.create(runtime,
                   scope: spec.scope,
                   id: id,
                   worker_id: context.native.id,
                   size_gb: 1
                 )

        assert {:ok, %{state: :ready}} = Volumes.inspect(runtime, key)
        {:ok, mount} = VolumeMount.new(id, "/mnt/volumes/#{id}")
        mount
      end

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Machines.create(runtime, %{spec | volumes: mounts})

    assert {:error, %{category: :not_found}} = Machines.inspect(runtime, {spec.scope, spec.id})
    assert {:ok, %{slots: 0, disk_gb: 3}} = Memory.usage(context.store, context.native.id)

    for mount <- mounts do
      assert {:ok, %{attached_to: nil}} = Volumes.inspect(runtime, {spec.scope, mount.volume_id})
    end

    refute Enum.any?(Package.received(context.native), fn request ->
             get_in(request, ["operation", "operation"]) in ["qualify_creation", "create"]
           end)
  end

  @tag volume_delay_ms: 100
  test "public volumes attach, retain proof/accounting through stopped replacement and delete normally",
       context do
    runtime = start_runtime(context)
    assert {:ok, volume_key} = create_volume(runtime, context.native)
    assert {:ok, %{state: :ready} = volume} = Volumes.inspect(runtime, volume_key)
    assert volume.native_authority.provision != nil
    assert {:ok, ^volume_key} = create_volume(runtime, context.native)
    assert [_] = volume_requests(context.native, "provision")
    assert {:ok, %{slots: 0, disk_gb: 4}} = Memory.usage(context.store, context.native.id)
    assert {:ok, machine_key} = Machines.create(runtime, machine_spec(context.native, "one"))

    assert {:ok, %{state: :stopped} = stopped} = Machines.await(runtime, machine_key, 5000),
           inspect(diagnostics(runtime, context))

    assert hd(stopped.native_mounts).proof == volume.native_authority.provision
    assert hd(stopped.native_mounts).readonly
    assert {:ok, <<"smolbox-record-v21\0", _::binary>>} = Codec.encode(stopped)
    assert {:ok, held} = Volumes.inspect(runtime, volume_key)
    assert held.attached_to == machine_key
    assert {:error, _} = Volumes.delete(runtime, volume_key, held.version)
    assert volume_requests(context.native, "delete") == []
    assert {:error, _} = Machines.create(runtime, machine_spec(context.native, "competing"))
    assert {:ok, %{slots: 1, disk_gb: 6}} = Memory.usage(context.store, context.native.id)
    assert {:ok, _} = Machines.start(runtime, machine_key, stopped.version)
    assert {:ok, running} = Machines.await(runtime, machine_key, 5000)
    assert running.state == :running, inspect(running.last_error)
    inspections = length(volume_requests(context.native, "inspect_provision"))

    assert {:ok, sibling_key} =
             Volumes.create(runtime,
               scope: "mounted",
               id: "sibling-data",
               worker_id: context.native.id,
               size_gb: 1
             )

    assert {:ok, sibling} = Volumes.inspect(runtime, sibling_key)
    await(fn -> ready?(runtime, context.native.id) end)
    assert {:ok, %{state: :running}} = Machines.inspect(runtime, machine_key)
    assert length(volume_requests(context.native, "inspect_provision")) == inspections
    assert {:ok, %{state: :deleted}} = Volumes.delete(runtime, sibling_key, sibling.version)
    assert {:ok, %{state: :running}} = Machines.inspect(runtime, machine_key)
    {:ok, command} = Command.new(["echo"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "mounted",
        id: "command",
        artifact: running.spec.artifact,
        profile: running.spec.profile,
        command: command
      )

    assert {:ok, execution} = Machines.submit(runtime, machine_key, spec)
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000)

    await(fn ->
      match?({:ok, %{active_execution: nil}}, Machines.inspect(runtime, machine_key))
    end)

    assert {:ok, running} = Machines.inspect(runtime, machine_key)
    assert {:ok, _} = Machines.stop(runtime, machine_key, running.version)
    assert {:ok, %{state: :stopped} = stopped} = Machines.await(runtime, machine_key, 5000)
    stop_supervised!({Runtime, __MODULE__})
    runtime = start_runtime(context)
    assert {:ok, ^held} = Volumes.inspect(runtime, volume_key)
    assert {:ok, recovered} = Machines.inspect(runtime, machine_key)
    assert recovered.native_mounts == stopped.native_mounts
    assert recovered.backend_assignment == stopped.backend_assignment
    assert {:ok, ^volume_key} = create_volume(runtime, context.native)
    assert [_] = volume_requests(context.native, "provision", volume.worker_volume_id)
    assert volume_requests(context.native, "inspect_provision") != []
    assert {:ok, _} = Machines.delete(runtime, machine_key, recovered.version)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, machine_key, 5000)
    assert {:ok, free} = Volumes.inspect(runtime, volume_key)
    assert free.attached_to == nil and free.native_authority == volume.native_authority
    assert {:ok, %{slots: 0, disk_gb: 4}} = Memory.usage(context.store, context.native.id)
    assert {:ok, %{state: :deleted} = deleted} = Volumes.delete(runtime, volume_key, free.version)
    assert deleted.native_authority.deletion["provision"] == volume.native_authority.provision
    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(context.store, context.native.id)
    assert {:ok, ^deleted} = Volumes.delete(runtime, volume_key, free.version)
    assert [_] = volume_requests(context.native, "delete", volume.worker_volume_id)
  end

  @tag volume_mode: "crossed"
  test "crossed provisioning proof remains unknown without replay and permits only explicit fenced cleanup",
       context do
    runtime = start_runtime(context)
    assert {:ok, key} = create_volume(runtime, context.native)
    assert {:ok, %{state: :unknown} = volume} = Volumes.inspect(runtime, key)
    assert volume.native_authority.provision == nil

    refute NativeAuthority.available?(
             Runtime.coordinator(runtime),
             context.native.id
           )

    assert {:ok, %{slots: 0, disk_gb: 4}} = Memory.usage(context.store, context.native.id)
    assert {:ok, ^key} = create_volume(runtime, context.native)
    assert [_] = volume_requests(context.native, "provision")

    assert {:error, %{evidence: :not_dispatched}} =
             Volumes.create(runtime,
               scope: "mounted",
               id: "second",
               worker_id: context.native.id,
               size_gb: 1
             )

    assert {:error, %{category: :not_found}} = Volumes.inspect(runtime, {"mounted", "second"})
    assert {:ok, %{slots: 0, disk_gb: 4}} = Memory.usage(context.store, context.native.id)
    assert {:error, _} = Volumes.resolve_delete(runtime, key, volume.version, [])
    stop_supervised!({Runtime, __MODULE__})
    runtime = start_runtime(context)
    assert {:ok, ^volume} = Volumes.inspect(runtime, key)
    assert [_] = volume_requests(context.native, "provision")

    assert {:ok, %{state: :deleted} = deleted} =
             fenced_cleanup(runtime, key, volume)

    assert deleted.native_authority.provision == deleted.native_authority.deletion["provision"]
    assert deleted.native_authority.deletion != nil
    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(context.store, context.native.id)
    assert [_] = volume_requests(context.native, "resolve_deletion")
  end

  test "explicit Linux approval and volume limits precede helper launch", context do
    native = context.native
    assert :ok = Config.validate(native)

    refute SDKIdentity.approved?(
             Config.sdk_identity(native),
             "1.22.0",
             native.package_identity["smolvm_revision"],
             :macos
           )

    {:ok, directory} = Launch.directory()
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, _} = Launch.prepare(native, directory)
    path = Path.join(native.package_path, "package.json")
    manifest = path |> File.read!() |> Jason.decode!()
    manifest = put_in(manifest["policy"]["volume_limits"]["control_metadata_bytes"], 0)
    bytes = Jason.encode!(manifest)
    File.write!(path, bytes)
    changed = %{native | package_manifest_sha256: Package.hash(bytes)}
    {:ok, second} = Launch.directory()
    on_exit(fn -> File.rm_rf!(second) end)
    assert :error = Launch.prepare(changed, second)
    assert Package.received(native) == []
  end

  defp operation_counts(native) do
    native
    |> Package.received()
    |> Enum.map(fn row ->
      if get_in(row, ["operation", "operation"]) == "volume",
        do: get_in(row, ["operation", "request", "action", "action"]),
        else: get_in(row, ["operation", "operation"])
    end)
    |> Enum.frequencies()
  end

  defp fenced_cleanup(runtime, key, volume, remaining \\ 100) do
    case Volumes.resolve_delete(runtime, key, volume.version, quiesced: true) do
      {:error, %{category: :admission_exhausted, evidence: :not_dispatched}} when remaining > 0 ->
        # Retry only a rejected admission whose exact durable intent is intact.
        assert {:ok, ^volume} = Volumes.inspect(runtime, key)
        Process.sleep(10)
        fenced_cleanup(runtime, key, volume, remaining - 1)

      result ->
        result
    end
  end

  defp diagnostics(runtime, context) do
    coordinator = Runtime.coordinator(runtime)
    state = :sys.get_state(coordinator)
    {:ok, config} = GenServer.call(coordinator, :config)
    worker = Enum.find(config.workers, &(&1.id == context.native.id))

    volume =
      case Volumes.inspect(runtime, {"mounted", "data"}) do
        {:ok, volume} ->
          target = Target.pin(worker)
          reference = Target.connection(target, volume)

          case EmbeddedVolume.run(
                 reference.context,
                 %{"action" => "inspect_provision"},
                 reference.budget
               ) do
            {:ok, outcome} ->
              {outcome["volume"]["status"],
               NativeVolumeRecovery.observation_valid?(volume, outcome)}

            error ->
              error
          end

        _ ->
          :none
      end

    {state.health, state.native_frozen, Map.keys(state.native_holders),
     operation_counts(context.native), volume}
  end

  defp await(function, remaining \\ 500, diagnostics \\ fn -> :timeout end)

  defp await(function, 0, diagnostics),
    do: assert(function.(), inspect(diagnostics.(), limit: 20))

  defp await(function, remaining, diagnostics) do
    if function.() do
      :ok
    else
      Process.sleep(10)
      await(function, remaining - 1, diagnostics)
    end
  end
end
