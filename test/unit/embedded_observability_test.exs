defmodule SmolBox.EmbeddedObservabilityTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.Embedded
  alias SmolBox.Embedded.{Config, Port, Protocol}
  alias SmolBox.Store.Memory
  alias SmolBox.Test.EmbeddedPackage, as: Package

  alias SmolBox.{
    Backend,
    Health,
    Machine,
    MachineMeasurements,
    Machines,
    ManagedMachineSpec,
    TestArtifacts,
    WorkerCapacity
  }

  setup do
    native = Package.create(protocol_major: 2, backend: true, persistent_backend: true)
    on_exit(fn -> File.rm_rf!(native.package_path) end)
    store = start_supervised!(Memory)
    artifacts = start_supervised!({Agent, fn -> %{} end})

    runtime =
      start_supervised!(
        SmolBox.child_spec(
          name: __MODULE__,
          namespace: "observe",
          mode: :ephemeral,
          store: {Memory, store},
          artifact_store: {TestArtifacts, artifacts},
          fingerprint_key: String.duplicate("k", 32),
          workers: [native],
          poll_ms: 50
        )
      )

    await(fn -> match?({:ok, [%{status: :ready}]}, SmolBox.workers(runtime)) end)
    owner = :global.whereis_name({Port, node()})
    {:ok, reference} = Embedded.reference(native, owner)
    %{native: native, runtime: runtime, store: store, reference: reference}
  end

  test "all node observations use public types and leave declared accounting separate", context do
    assert {:ok, %Health{version: "1.22.0", total: 0, running: 0}} =
             Backend.health(context.reference)

    assert :ok = Backend.readiness(context.reference)
    assert {:ok, []} = Backend.list(context.reference)
    assert {:ok, text} = Backend.metrics(context.reference)
    assert text =~ "smolbox_native_machines 0"

    assert {:ok,
            %WorkerCapacity{
              allocated_cpus: 0,
              used_cpus: zero,
              used_memory_pss_mb: nil,
              host_memory_available_mb: nil
            }} = Backend.capacity(context.reference)

    assert zero == 0
    assert {:ok, report} = SmolBox.worker_report(context.runtime, context.native.id)
    assert report.capacity_error == nil and report.observed_capacity.allocated_cpus == 0
    assert report.reserved.slots == 0
    assert report.worker.capacity.slots == context.native.capacity.slots

    await(fn ->
      match?({:ok, [%{health: %{inventory: %{total: 0}}}]}, SmolBox.workers(context.runtime))
    end)

    assert {:ok, [worker]} = SmolBox.workers(context.runtime)
    assert worker.health.inventory.total == 0
  end

  test "inventory never supplies receipts and stopped measurements retain capacity", context do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "observe",
        id: "retained",
        profile: hd(context.native.profiles),
        artifact: hd(context.native.artifacts) |> Map.take(~w(id sha256 architecture))
      )

    assert {:ok, handle} = Machines.create(context.runtime, spec)
    assert {:ok, %{state: :stopped} = record} = Machines.await(context.runtime, handle, 5000)
    assert {:ok, [listed]} = Backend.list(context.reference)
    assert listed.name == record.machine_name and listed.backend_identity == nil
    refute Machine.same_incarnation?(record.created_machine, listed)

    assert {:ok,
            %MachineMeasurements{
              machine: observed,
              cpu_millis: nil,
              rss_mb: nil,
              egress_bytes: nil
            }} = Machines.measurements(context.runtime, handle)

    assert Machine.same_incarnation?(record.created_machine, observed)
    assert {:ok, report} = SmolBox.worker_report(context.runtime, context.native.id)
    assert report.reserved.slots == 1 and report.observed_capacity.allocated_cpus == 0

    assert {:ok, %{reservation: reservation, backend_assignment: assignment}} =
             Machines.inspect(context.runtime, handle)

    assert reservation == record.reservation and assignment == record.backend_assignment
    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.native.id)
  end

  test "legacy protocol-2 SDK approval preserves its narrower capabilities", context do
    legacy_sdk =
      Config.sdk_identity(context.native)
      |> update_in(
        ["feature_versions"],
        &Map.drop(
          &1,
          ~w(observability compact_creation job_resources buffered_exec background_exec logs streaming_exec terminals)
        )
      )

    legacy = %{context.native | sdk_identity: legacy_sdk}
    assert :ok = Config.validate(legacy)
    assert Protocol.capabilities(legacy_sdk) == Protocol.capabilities()
    assert Protocol.limits(2, 0, legacy_sdk) == Protocol.limits(4)
    {:ok, reference} = Embedded.reference(legacy, :global.whereis_name({Port, node()}))

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.capacity(reference)

    planned = put_in(legacy_sdk, ["feature_versions", "terminals"], 1)
    assert {:error, %{category: :validation}} = Config.validate(%{legacy | sdk_identity: planned})
  end

  test "observation wire shapes remain versioned, correlated and bounded", context do
    outcome = %{
      "result" => "health",
      "snapshot" => %{"total" => 1, "running" => 1, "uptime_seconds" => 0}
    }

    assert Protocol.valid_outcome?(outcome, 2)
    refute Protocol.valid_outcome?(outcome, 1)
    refute Protocol.valid_outcome?(put_in(outcome, ["snapshot", "running"], 2), 2)
    refute Protocol.valid_outcome?(put_in(outcome, ["snapshot", "private"], "secret"), 2)

    assert Enum.member?(
             Protocol.capabilities(Config.sdk_identity(context.native)),
             "measurements"
           )

    assert Protocol.limits(2, 0)["observations"]["records"] == 1024

    assert {:error, %{category: :unsupported_capability}} =
             Backend.metrics(%{
               context.reference
               | context: %{
                   context.reference.context
                   | config: %{
                       context.native
                       | package_identity: %{
                           context.native.package_identity
                           | "engine_version" => "0.1.0"
                         },
                         sdk_identity: nil
                     }
                 }
             })
  end

  defp await(check, attempts \\ 200)
  defp await(_check, 0), do: flunk("observational fixture did not become ready")

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
