defmodule SmolBox.Store.NativeExportContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{ExportContract, ExportPublication, ExportStageCleanup}
  alias SmolBox.{ExportDestination, ExportSpec, ManagedMachine}
  alias SmolBox.Store.{Codec, Contract, ExportOps, NativeCaptureContract}

  def fixture do
    record = NativeCaptureContract.fixture()

    spec = %{
      record.spec
      | checkpointable: false,
        artifact: Map.put(record.spec.artifact, "architecture", "x86_64")
    }

    assignment = %{
      record.backend_assignment
      | creation:
          record.backend_assignment.creation
          |> Map.delete("checkpointable")
          |> put_in(["artifact", "guest_platform"], "linux/amd64")
    }

    record = %{record | spec: spec, backend_assignment: assignment}
    assert :ok = ManagedMachine.validate(record)

    {:ok, destination} =
      ExportDestination.new(
        id: "fixture-registry",
        registry: "registry.example",
        repository: "team/artifact",
        credential_ref: "publisher",
        immutable_tags: true,
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    {:ok, spec} = ExportSpec.new(id: "fixture-export", destination: destination, tag: "release")

    wire =
      "../../../native/smolbox-protocol/fixtures/export-publications-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> hd()

    {:ok, proof} = ExportPublication.from_wire(wire)
    assert proof.source == record.created_machine.backend_identity.receipt
    [approval] = ExportContract.approvals(%{export_destinations: [destination]})

    request = %{
      "request_sha256" => proof.request_sha256,
      "destination_id" => destination.id,
      "destination_sha256" => approval["destination_sha256"],
      "tag" => spec.tag,
      "max_artifact_bytes" => 8_589_934_592,
      "max_staging_bytes" => 137_438_953_472
    }

    capacity = %{slots: 16, cpus: 64, memory_mb: 131_072, disk_gb: 1024}
    usage = Map.new(capacity, fn {key, _} -> {key, 0} end)

    assert {:ok, accepted} =
             ExportOps.accept(record, spec, proof.request_sha256, capacity, usage, [record], 1100)

    {record, accepted, spec, request, proof}
  end

  def prepare(adapter, store, uncertain \\ true) do
    {original, _, spec, request, proof} = fixture()
    key = ManagedMachine.key(original)
    assert {:ok, %{native_export_histories: 1}} = adapter.capabilities(store)

    assert {:ok, _} =
             adapter.bind_backend(store, original.worker_id, original.backend_assignment.binding)

    assert {:ok, _} = adapter.claim_worker(store, original.worker_id, "owner", 1000, 10_000)
    {:ok, initial} = ManagedMachine.new(original.spec, original.fingerprint, 1000)
    assert {:ok, _} = adapter.machine(store, :accept, [initial, 10])
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1000, 10_000])
    capacity = %{slots: 16, cpus: 64, memory_mb: 131_072, disk_gb: 1024}

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {original.worker_id, original.machine_name, capacity, original.backend_assignment},
               1000
             ])

    assert {:ok, stopped} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(reserved),
               [
                 state: :stopped,
                 operation: nil,
                 phase: nil,
                 created_machine: original.created_machine,
                 observed_machine: original.observed_machine
               ],
               1001
             ])

    assert {:ok, accepted} =
             adapter.machine(store, :export_accept, [
               key,
               spec,
               proof.request_sha256,
               capacity,
               1100
             ])

    assert accepted.exports[spec.id].native_authority.source == proof.source

    assert {:ok, ^accepted} =
             adapter.machine(store, :export_accept, [
               key,
               spec,
               proof.request_sha256,
               capacity,
               1100
             ])

    assert {:ok, sent} =
             adapter.machine(store, :export_advance, [
               key,
               Contract.guard(accepted),
               spec.id,
               :accepted,
               [state: :dispatching, native_request: request],
               1101
             ])

    unknown =
      if uncertain do
        assert {:ok, unknown} = adapter.machine(store, :export_cancel, [key, spec.id, 1102])
        unknown
      else
        sent
      end

    assert unknown.exports[spec.id].native_authority == sent.exports[spec.id].native_authority
    assert {:ok, %{slots: 2, disk_gb: 130}} = adapter.usage(store, original.worker_id)
    {stopped, unknown, spec, proof}
  end

  def lifecycle(adapter, store) do
    {stopped, unknown, spec, _} = prepare(adapter, store)
    original = stopped
    key = ManagedMachine.key(unknown)

    assert {:error, _} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               stopped.observed_machine,
               1103
             ])

    wire =
      "../../../native/smolbox-protocol/fixtures/export-cleanups-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> hd()

    {:ok, cleanup} = ExportStageCleanup.from_wire(wire)

    assert {:error, _} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               stopped.observed_machine,
               %{cleanup | operation_id: "foreign"},
               1103
             ])

    assert {:ok, ^unknown} = adapter.machine(store, :fetch, [key])

    assert {:ok, resolved} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               stopped.observed_machine,
               cleanup,
               1103
             ])

    assert resolved.active_export == nil and resolved.state == :stopped
    assert resolved.exports[spec.id].state == :resolved_unknown
    assert resolved.exports[spec.id].result == nil and resolved.exports[spec.id].receipt == nil
    assert resolved.exports[spec.id].native_authority.cleanup == cleanup
    assert resolved.created_machine == stopped.created_machine
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, original.worker_id)

    assert {:error, _} =
             adapter.machine(store, :export_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               stopped.observed_machine,
               cleanup,
               1104
             ])

    assert {:ok, <<"smolbox-record-v28\0", _::binary>> = bytes} = Codec.encode(resolved)
    assert {:ok, ^resolved} = Codec.decode(bytes)
    resolved
  end
end
