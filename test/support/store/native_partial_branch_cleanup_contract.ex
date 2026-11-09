defmodule SmolBox.Store.NativePartialBranchCleanupContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchPublication,
    NativePartialBranchCleanupResult,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup
  }

  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{Codec, NativeBranchContract, NativePartialBranchDisposalContract}

  alias NativePartialBranchDisposalContract, as: Disposal

  defdelegate fetch(adapter, store, record), to: Disposal
  defdelegate resolve(adapter, store, parent, child, result, now), to: Disposal

  def prepare(adapter, store, mode) do
    {parent, child, metadata, usage} = Disposal.prepare(adapter, store, mode)
    assert {:ok, pending} = Disposal.accept(adapter, store, parent, child, child.version, 1400)
    {fetch(adapter, store, parent), pending, metadata, usage}
  end

  def accept(adapter, store, parent, child, version, now, platform \\ "macos"),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        child.branch.state,
        {:accept_partial_disposal_cleanup, version, platform},
        now
      )

  # Synthetic typed cleanup + source projections, never filesystem or SDK calls.
  def result(child, metadata) do
    common = Disposal.result(child, metadata, "resolved_absent")
    request = child.branch.native_authority.partial_disposal.cleanup.request

    wire = %{
      "schema" => 1,
      "request" => request,
      "disposal" => PartialBranchDisposal.to_wire(common.proof)
    }

    wire = Map.put(wire, "proof_sha256", PartialBranchDisposalCleanup.proof_digest(wire))
    assert {:ok, proof} = PartialBranchDisposalCleanup.from_wire(wire)
    %NativePartialBranchCleanupResult{version: child.version, source: common.source, proof: proof}
  end

  def complete(adapter, store, mode) do
    {parent, child, metadata, usage} = prepare(adapter, store, mode)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1401)
    source = fetch(adapter, store, parent)
    saved = pending.branch.native_authority.partial_disposal.cleanup
    assert_pending(source, child, pending, saved)
    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    assert {:ok, ^pending} = accept(adapter, store, source, pending, saved.version, 1402)
    assert {:ok, ^pending} = accept(adapter, store, source, pending, pending.version, 1402)
    result = result(pending, metadata)
    assert {:ok, completed} = resolve(adapter, store, source, pending, result, 1403)
    source = fetch(adapter, store, parent)
    assert_completed(child, pending, completed, result)
    assert_source(parent, child, source, result)
    assert {:ok, expected} = adapter.usage(store, source.worker_id)

    assert expected ==
             Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

    for record <- [pending, completed] do
      assert ManagedMachine.validate(record) == :ok
      assert {:ok, <<"smolbox-record-v48", 0, _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    assert {:ok, bytes} = Codec.encode(source)
    assert {:ok, ^source} = Codec.decode(bytes)
    {source, completed, pending, result, expected}
  end

  defp assert_pending(source, child, pending, saved) do
    disposal = child.branch.native_authority.partial_disposal
    assert pending.branch.state == :disposal_cleanup_pending and pending.state == :unknown
    assert saved.version == child.version and saved.version > disposal.version
    assert saved.request["disposal_request"] == disposal.request
    assert saved.proof == nil and saved.platform == disposal.platform
    assert pending.reservation == child.reservation
    assert source.active_branch == child.id and source.branch_children == %{child.id => false}
    assert source.native_branch_history == %{}
  end

  defp assert_completed(child, pending, completed, result) do
    disposal = child.branch.native_authority.partial_disposal
    saved = pending.branch.native_authority.partial_disposal.cleanup
    after_disposal = completed.branch.native_authority.partial_disposal
    assert completed.branch.state == :disposed and completed.state == :deleted
    assert completed.reservation == nil and ManagedMachine.idle?(completed)

    assert completed.branch.native_authority.partial_collection ==
             child.branch.native_authority.partial_collection

    assert after_disposal.request == disposal.request and
             after_disposal.version == disposal.version

    assert after_disposal.cleanup.request == saved.request

    assert after_disposal.cleanup.version == saved.version and
             after_disposal.cleanup.proof == result.proof

    assert after_disposal.completion_version == pending.version
    assert after_disposal.cleanup.completion_version == pending.version
    assert PartialBranchDisposal.to_wire(after_disposal.proof) == result.proof.disposal

    assert completed.branch.native_authority.retirement == nil and
             completed.branch.native_authority.backing == nil
  end

  defp assert_source(parent, child, source, result) do
    assert source.active_branch == nil and source.branch_children == %{child.id => false}
    assert {:ok, publication} = BranchPublication.from_wire(result.proof.disposal["publication"])
    assert source.native_branch_history == %{child.id => publication}

    assert source.observed_machine == result.source and
             source.created_machine == parent.created_machine
  end
end
