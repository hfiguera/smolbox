defmodule SmolBox.Store.NativePartialBranchCollectionContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    NativePartialBranchCollectionResult,
    PartialBranchCollection
  }

  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{NativeBranchContract, NativeUnbootedBranchDisposalContract}
  defdelegate prepare(adapter, store, hold), to: NativeUnbootedBranchDisposalContract
  defdelegate fetch(adapter, store, record), to: NativeUnbootedBranchDisposalContract

  def accept(adapter, store, parent, child, version, now),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        :unknown,
        {:accept_partial_collection, version, "macos"},
        now
      )

  def result(child) do
    saved = child.branch.native_authority.partial_collection

    proof = %{
      "schema" => 1,
      "creation_sha256" =>
        BranchCanonical.digest(
          BranchCanonical.ordered(saved.request["creation"], :creation_request)
        ),
      "publication_sha256" => String.duplicate("e", 64),
      "operation_id" => saved.request["operation_id"],
      "request_sha256" => saved.request["request_sha256"],
      "boot_sha256" => String.duplicate("a", 64),
      "collection_sha256" => String.duplicate("b", 64)
    }

    proof = Map.put(proof, "proof_sha256", PartialBranchCollection.proof_digest(proof))
    {:ok, proof} = PartialBranchCollection.from_wire(proof)

    %NativePartialBranchCollectionResult{
      version: child.version,
      proof: proof,
      platform: saved.platform
    }
  end

  def finish(adapter, store, parent, child, result, now),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        :unknown,
        {:complete_partial_collection, result},
        now
      )

  def complete(adapter, store, hold) do
    {parent, child, _, usage} = prepare(adapter, store, hold)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1103)
    current = fetch(adapter, store, parent)
    assert pending.branch.state == :unknown and pending.state == :unknown
    saved = pending.branch.native_authority.partial_collection
    assert saved.version == child.version and saved.proof == nil
    assert {:ok, ^pending} = accept(adapter, store, current, pending, child.version, 1104)
    proof = result(pending)
    assert {:ok, collected} = finish(adapter, store, current, pending, proof, 1105)
    source = fetch(adapter, store, parent)
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert collected.branch.native_authority.partial_collection.proof == proof.proof

    assert collected.branch.native_authority.partial_collection.completion_version ==
             pending.version

    assert_retained(source, collected, parent, child)
    assert {:ok, ^collected} = finish(adapter, store, source, collected, proof, 1106)
    assert {:ok, ^collected} = accept(adapter, store, source, collected, child.version, 1106)
    assert ManagedMachine.validate(collected) == :ok
    {source, collected, usage, pending}
  end

  defp assert_retained(source, collected, parent, child) do
    assert collected.state == :unknown and collected.branch.state == :unknown
    assert collected.operation == :branch_child and collected.reservation == child.reservation

    assert collected.created_machine == nil and collected.observed_machine == nil and
             collected.absence_at_ms == nil

    assert source.active_branch == child.id and source.operation == :branch and
             source.branch_children == %{child.id => false}

    assert source.native_branch_history == %{} and
             source.created_machine == parent.created_machine and
             source.observed_machine == parent.observed_machine
  end
end
