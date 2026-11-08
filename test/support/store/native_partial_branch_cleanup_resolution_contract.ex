defmodule SmolBox.Store.NativePartialBranchCleanupResolutionContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchPublication,
    NativePartialBranchCleanupResolutionResult,
    NativePartialBranchCleanupResult,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded
  }

  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    Contract,
    NativePartialBranchBackingContract,
    NativePartialBranchCleanupContract,
    NativePartialBranchDisposalContract,
    NativePartialBranchRetirementContract
  }

  alias NativePartialBranchCleanupContract, as: Cleanup

  defdelegate fetch(adapter, store, record), to: Cleanup
  defdelegate prepare(adapter, store, mode), to: Cleanup
  defdelegate accept(adapter, store, parent, child, version, now), to: Cleanup
  defdelegate resolve(adapter, store, parent, child, result, now), to: Cleanup

  # Synthetic original terminal projections; no native owner/SDK/VM qualification.
  def result(child, metadata, provenance) do
    common = NativePartialBranchDisposalContract.result(child, metadata, provenance)
    request = child.branch.native_authority.partial_disposal.cleanup.request

    wire = %{
      "schema" => 1,
      "request" => request,
      "disposal" => PartialBranchDisposal.to_wire(common.proof)
    }

    wire = Map.put(wire, "proof_sha256", PartialBranchDisposalCleanupUnneeded.proof_digest(wire))
    assert {:ok, proof} = PartialBranchDisposalCleanupUnneeded.from_wire(wire)

    %NativePartialBranchCleanupResolutionResult{
      version: child.version,
      source: common.source,
      proof: proof
    }
  end

  def complete(adapter, store, mode, provenance) do
    {parent, child, metadata, usage} = prepare(adapter, store, mode)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1401)
    source = fetch(adapter, store, parent)
    saved = pending.branch.native_authority.partial_disposal.cleanup
    assert saved.proof == nil and saved.unneeded == nil and saved.completion_version == nil
    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    assert {:ok, ^pending} = accept(adapter, store, source, pending, saved.version, 1402)
    response = result(pending, metadata, provenance)
    assert NativePartialBranchCleanupResolutionResult.bound?(response, source, pending)

    refute NativePartialBranchCleanupResult.bound?(
             %NativePartialBranchCleanupResult{
               version: pending.version,
               source: response.source,
               proof: response.proof
             },
             source,
             pending
           )

    assert {:ok, completed} = resolve(adapter, store, source, pending, response, 1403)
    source = fetch(adapter, store, parent)
    assert_completed(child, pending, completed, response, provenance)

    assert source.branch_children == %{child.id => false} and source.active_branch == nil

    assert source.created_machine == parent.created_machine and
             source.observed_machine == response.source

    assert {:ok, publication} =
             BranchPublication.from_wire(response.proof.disposal["publication"])

    assert source.native_branch_history == %{child.id => publication}
    assert {:ok, expected} = adapter.usage(store, source.worker_id)

    assert expected ==
             Map.merge(usage, Profile.resources(child.spec.profile), fn _, total, ordinary ->
               total - ordinary
             end)

    assert {:ok, <<"smolbox-record-v48", 0, _::binary>> = old} = Codec.encode(pending)
    assert {:ok, ^pending} = Codec.decode(old)
    assert {:ok, <<"smolbox-record-v49", 0, _::binary>> = bytes} = Codec.encode(completed)
    assert {:ok, ^completed} = Codec.decode(bytes)
    assert {:ok, source_bytes} = Codec.encode(source)
    assert {:ok, ^source} = Codec.decode(source_bytes)
    {source, completed, pending, response, expected}
  end

  defp assert_completed(child, pending, completed, response, provenance) do
    saved = pending.branch.native_authority.partial_disposal.cleanup
    disposal = completed.branch.native_authority.partial_disposal
    assert disposal.request == child.branch.native_authority.partial_disposal.request
    assert disposal.cleanup.request == saved.request and disposal.cleanup.version == saved.version
    assert disposal.cleanup.proof == nil and disposal.cleanup.unneeded == response.proof

    assert disposal.cleanup.completion_version == pending.version and
             disposal.completion_version == pending.version

    assert PartialBranchDisposal.to_wire(disposal.proof) == response.proof.disposal
    assert disposal.proof.completion == provenance

    assert completed.branch.native_authority.partial_collection ==
             child.branch.native_authority.partial_collection

    assert completed.state == :deleted and completed.branch.state == :disposed and
             ManagedMachine.idle?(completed)

    assert completed.reservation == nil and completed.reserved_ports == []
    assert completed.created_machine == nil and completed.observed_machine == nil

    assert completed.branch.native_authority.retirement == nil and
             completed.branch.native_authority.backing == nil
  end

  def reject_crossed(adapter, store) do
    {parent, child, metadata, usage} = prepare(adapter, store, :explicit_release)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1401)
    source = fetch(adapter, store, parent)
    response = result(pending, metadata, "deleted")
    request = Map.put(response.proof.request, "operation_id", "other-unneeded-cleanup")

    request =
      Map.put(request, "request_sha256", PartialBranchDisposalCleanup.request_digest(request))

    proof = %{response.proof | request: request}

    proof = %{
      proof
      | proof_sha256:
          PartialBranchDisposalCleanupUnneeded.proof_digest(
            PartialBranchDisposalCleanupUnneeded.to_wire(proof)
          )
    }

    assert PartialBranchDisposalCleanupUnneeded.valid?(proof)

    for wrong <- [
          %{response | version: pending.version + 1},
          %{response | proof: proof},
          %{response | proof: PartialBranchDisposalCleanupUnneeded.to_wire(response.proof)},
          %{response | proof: Map.put(response.proof, :extra, true)},
          %{response | source: %{response.source | network: :enabled}},
          put_in(response.source.backend_identity.pid_identity, [999, 999]),
          put_in(
            response.source.backend_identity.receipt["material"]["record_sha256"],
            String.duplicate("f", 64)
          )
        ] do
      refute NativePartialBranchCleanupResolutionResult.bound?(wrong, source, pending)
      assert {:error, _} = resolve(adapter, store, source, pending, wrong, 1402)
      assert fetch(adapter, store, parent) == source and fetch(adapter, store, child) == pending
      assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    end

    removal = Cleanup.result(pending, metadata)
    wrong = %{response | proof: removal.proof}
    refute NativePartialBranchCleanupResolutionResult.bound?(wrong, source, pending)
    assert {:error, _} = resolve(adapter, store, source, pending, wrong, 1402)

    wrong = %NativePartialBranchCleanupResult{
      version: pending.version,
      source: response.source,
      proof: response.proof
    }

    refute NativePartialBranchCleanupResult.bound?(wrong, source, pending)
    assert {:error, _} = resolve(adapter, store, source, pending, wrong, 1402)
    assert fetch(adapter, store, parent) == source and fetch(adapter, store, child) == pending
    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
  end

  def close_storage(adapter, store, parent, child) do
    saved = child.branch.native_authority.partial_disposal
    proof = NativePartialBranchRetirementContract.proof(child)

    assert {:ok, retired} =
             NativePartialBranchRetirementContract.advance(
               adapter,
               store,
               parent,
               child,
               proof,
               1500
             )

    parent = fetch(adapter, store, parent)

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(parent),
               :delete,
               parent.version,
               1501
             ])

    assert {:ok, source} =
             adapter.machine(store, :write, [
               ManagedMachine.key(parent),
               Contract.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: 1502
               ],
               1502
             ])

    assert {:ok, pending} =
             NativePartialBranchBackingContract.accept(adapter, store, source, retired, 1503)

    source = fetch(adapter, store, source)

    backing =
      NativePartialBranchBackingContract.proof(pending.branch.native_authority.backing.request)

    assert {:ok, closed} =
             NativePartialBranchBackingContract.complete_proof(
               adapter,
               store,
               source,
               pending,
               backing,
               1504
             )

    for record <- [retired, pending, closed] do
      assert record.branch.native_authority.partial_disposal == saved
      assert {:ok, <<"smolbox-record-v49", 0, _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    assert {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
             adapter.usage(store, parent.worker_id)
  end
end
