defmodule SmolBox.Store.NativePartialBranchDisposalContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    NativePartialBranchDisposalResult,
    PartialBranchCollection,
    PartialBranchDisposal
  }

  alias SmolBox.{Branch, ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    Contract,
    NativeBranchContract,
    NativePartialBranchCollectionContract,
    NativeUnbootedBranchDisposalContract
  }

  defdelegate fetch(adapter, store, record), to: NativeUnbootedBranchDisposalContract

  # Synthetic canonical store/observation projections only. No native owner,
  # collection, SDK deletion, VM or platform qualification is supplied here.
  def prepare(adapter, store, mode) do
    hold = mode in [:held, :explicit_release]

    {parent, child, completion, usage} =
      NativeUnbootedBranchDisposalContract.prepare(adapter, store, hold)

    assert {:ok, pending} =
             NativePartialBranchCollectionContract.accept(
               adapter,
               store,
               parent,
               child,
               child.version,
               1103
             )

    parent = fetch(adapter, store, parent)
    release = release(mode, completion.completion)
    collection = NativePartialBranchCollectionContract.result(pending)

    wire =
      collection.proof
      |> PartialBranchCollection.to_wire()
      |> Map.merge(%{
        "publication_sha256" =>
          BranchCanonical.digest(
            BranchCanonical.ordered(completion.completion.publication, :publication)
          ),
        "boot_sha256" =>
          if(release, do: release["change"]["boot_sha256"], else: String.duplicate("a", 64))
      })

    wire = Map.put(wire, "proof_sha256", PartialBranchCollection.proof_digest(wire))
    assert {:ok, proof} = PartialBranchCollection.from_wire(wire)

    assert {:ok, collected} =
             NativePartialBranchCollectionContract.finish(
               adapter,
               store,
               parent,
               pending,
               %{collection | proof: proof},
               1104
             )

    source = fetch(adapter, store, parent)

    {source, collected,
     %{
       publication: completion.completion.publication,
       release: release,
       source: completion.source
     }, usage}
  end

  defp release(:initial_release, completion), do: completion.release
  defp release(mode, _) when mode in [:held, :pre_release], do: nil

  defp release(:explicit_release, completion) do
    template =
      Path.expand("../../../native/smolbox-protocol/fixtures/branch-creation-v1.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Enum.find(& &1["completion"]["release"])
      |> get_in(["completion", "release"])

    root = completion.publication["change"]["child"]

    request = %{
      "operation_id" => "explicit-partial-model",
      "request_sha256" => String.duplicate("d", 64)
    }

    change = %{
      template["change"]
      | "mode" => "explicit",
        "binding" => completion.publication["change"]["child_origin"],
        "request" => request
    }

    material = %{
      template["receipt"]["material"]
      | "operation_id" => request["operation_id"],
        "request_sha256" => request["request_sha256"]
    }

    material = %{
      material
      | "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-branch-child-release-v1",
            BranchCanonical.ordered(root, :receipt),
            BranchCanonical.ordered(change, :release_change),
            material["record_sha256"]
          ])
    }

    %{
      template
      | "previous" => root,
        "receipt" => Map.put(root, "material", material),
        "change" => change
    }
  end

  def accept(adapter, store, parent, child, version, now, platform \\ "macos"),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        child.branch.state,
        {:accept_partial_disposal, version, platform},
        now
      )

  def result(child, metadata, provenance \\ "deleted") do
    proof = %{
      "schema" => 1,
      "completion" => provenance,
      "request" => child.branch.native_authority.partial_disposal.request,
      "publication" => metadata.publication,
      "disposal_sha256" => String.duplicate("e", 64)
    }

    proof = if metadata.release, do: Map.put(proof, "release", metadata.release), else: proof
    proof = Map.put(proof, "proof_sha256", PartialBranchDisposal.proof_digest(proof))
    assert {:ok, proof} = PartialBranchDisposal.from_wire(proof)

    %NativePartialBranchDisposalResult{
      version: child.version,
      source: metadata.source,
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

  def complete(adapter, store, mode, provenance) do
    {parent, child, metadata, usage} = prepare(adapter, store, mode)
    collection = child.branch.native_authority.partial_collection
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1105)
    source = fetch(adapter, store, parent)
    saved = pending.branch.native_authority.partial_disposal

    assert saved.version == child.version and saved.proof == nil and
             saved.platform == collection.platform

    assert pending.reservation == child.reservation and pending.branch.state == :disposal_pending
    assert pending.branch.native_authority.partial_collection == collection
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^pending} = accept(adapter, store, source, pending, saved.version, 1106)
    result = result(pending, metadata, provenance)
    assert {:ok, disposed} = resolve(adapter, store, source, pending, result, 1107)
    source = fetch(adapter, store, parent)
    assert_disposed(disposed, collection, pending, child, result)
    assert {:ok, publication} = BranchPublication.from_wire(metadata.publication)
    assert source.native_branch_history == %{child.id => publication}
    assert source.branch_children == %{child.id => false} and source.active_branch == nil

    assert source.created_machine == parent.created_machine and
             source.observed_machine == result.source

    assert {:ok, expected} = adapter.usage(store, source.worker_id)

    assert expected ==
             Map.merge(usage, Profile.resources(child.spec.profile), fn _, total, ordinary ->
               total - ordinary
             end)

    for record <- [pending, disposed, source] do
      assert ManagedMachine.validate(record) == :ok
      assert {:ok, bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    {source, disposed, pending, result, expected}
  end

  defp assert_disposed(disposed, collection, pending, child, result) do
    assert disposed.state == :deleted and disposed.branch.state == :disposed
    assert disposed.reservation == nil and ManagedMachine.idle?(disposed)
    assert disposed.created_machine == nil and disposed.observed_machine == nil
    assert disposed.branch.native_authority.completion == nil
    assert disposed.branch.native_authority.partial_collection == collection
    assert disposed.branch.native_authority.partial_disposal.proof == result.proof
    assert disposed.branch.native_authority.partial_disposal.completion_version == pending.version
    assert Branch.resources(disposed) == child.branch.spec.policy.resources
  end
end
