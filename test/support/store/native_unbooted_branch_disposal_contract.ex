defmodule SmolBox.Store.NativeUnbootedBranchDisposalContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchPublication,
    NativeUnbootedBranchDisposalResult,
    UnbootedBranchDisposal
  }

  alias SmolBox.{ManagedMachine, Profile}
  alias SmolBox.Store.{Codec, Contract, NativeBranchContract}

  # Private typed history/accounting models, never SDK ownership or VM evidence.
  def prepare(adapter, store, hold) do
    {parent, child, completion} = NativeBranchContract.prepare(adapter, store, hold)

    assert {:ok, _} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               child,
               :accepted,
               :dispatching,
               1101
             )

    parent = fetch(adapter, store, parent)

    assert {:ok, child} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               child,
               :dispatching,
               :unknown,
               1102
             )

    parent = fetch(adapter, store, parent)
    assert {:ok, usage} = adapter.usage(store, parent.worker_id)
    {parent, child, completion, usage}
  end

  def accept(adapter, store, parent, child, version, now),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        child.branch.state,
        {:accept_unbooted_disposal, version},
        now
      )

  def fetch(adapter, store, record) do
    assert {:ok, record} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
    record
  end

  def result(child, completion, provenance \\ "deleted") do
    request = child.branch.native_authority.disposal.request

    proof = %{
      "schema" => 1,
      "completion" => provenance,
      "creation" => request["creation"],
      "request" => request["request"],
      "publication" => completion.completion.publication,
      "disposal_sha256" => String.duplicate("e", 64)
    }

    proof = Map.put(proof, "proof_sha256", UnbootedBranchDisposal.proof_digest(proof))
    assert {:ok, proof} = UnbootedBranchDisposal.from_wire(proof)

    %NativeUnbootedBranchDisposalResult{
      version: child.version,
      source: completion.source,
      proof: proof
    }
  end

  def resolve(adapter, store, parent, child, result, now),
    do:
      adapter.machine(store, :branch_resolve, [
        ManagedMachine.key(parent),
        Contract.guard(parent),
        child.id,
        result.source,
        result,
        now
      ])

  def complete(adapter, store, hold, provenance \\ "deleted") do
    {parent, child, completion, usage} = prepare(adapter, store, hold)
    assert {:ok, accepted} = accept(adapter, store, parent, child, child.version, 1103)
    source = fetch(adapter, store, parent)
    saved = accepted.branch.native_authority.disposal
    assert saved.version == child.version and saved.proof == nil
    assert accepted.reservation == child.reservation
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    result = result(accepted, completion, provenance)
    assert {:ok, disposed} = resolve(adapter, store, source, accepted, result, 1104)
    source = fetch(adapter, store, source)
    assert disposed.state == :deleted and disposed.branch.state == :disposed

    assert disposed.created_machine == nil and disposed.observed_machine == nil and
             disposed.reservation == nil

    assert disposed.branch.native_authority.completion == nil
    assert disposed.branch.native_authority.disposal.proof == result.proof
    assert disposed.branch.native_authority.disposal.completion_version == accepted.version
    assert {:ok, publication} = BranchPublication.from_wire(result.proof.publication)
    assert source.native_branch_history == %{child.id => publication}
    assert source.branch_children == %{child.id => false} and source.active_branch == nil

    assert source.created_machine == parent.created_machine and
             source.observed_machine == result.source

    assert {:ok, expected} = adapter.usage(store, parent.worker_id)

    assert expected ==
             Map.merge(usage, Profile.resources(child.spec.profile), fn _, total, ordinary ->
               total - ordinary
             end)

    for record <- [accepted, disposed, source] do
      assert :ok = ManagedMachine.validate(record)
      assert {:ok, bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    {source, disposed, result, expected}
  end
end
