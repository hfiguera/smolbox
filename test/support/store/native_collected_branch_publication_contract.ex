defmodule SmolBox.Store.NativeCollectedBranchPublicationContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    NativeCollectedBranchPublicationResult,
    PartialBranchCollection
  }

  alias SmolBox.Store.{
    Codec,
    NativeBranchContract,
    NativePartialBranchCollectionContract,
    NativePartialBranchDisposalContract,
    NativeUnbootedBranchDisposalContract
  }

  defdelegate prepare(adapter, store, hold), to: NativeUnbootedBranchDisposalContract
  defdelegate fetch(adapter, store, record), to: NativeUnbootedBranchDisposalContract

  # Synthetic proof and observation projections only; no live native authority.
  def accept(adapter, store, parent, child, version, now),
    do:
      NativeBranchContract.advance(
        adapter,
        store,
        parent,
        child,
        :unknown,
        {:accept_collected_publication, version, "macos"},
        now
      )

  def result(child, completion) do
    {:ok, proof} = BranchPublication.from_wire(completion.completion.publication)

    %NativeCollectedBranchPublicationResult{
      version: child.version,
      platform: "macos",
      proof: proof,
      source: completion.source
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
        {:complete_collected_publication, result},
        now
      )

  def complete(adapter, store, hold) do
    {parent, child, completion, usage} = prepare(adapter, store, hold)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1103)
    source = fetch(adapter, store, parent)
    saved = pending.branch.native_authority.collected_publication
    assert saved.version == child.version and saved.proof == nil

    assert saved.request == %{
             "creation" => child.branch.native_authority.request,
             "quiesced" => true
           }

    assert {:ok, ^pending} = accept(adapter, store, source, pending, saved.version, 1104)
    result = result(pending, completion)
    assert {:ok, published} = finish(adapter, store, source, pending, result, 1105)
    source = fetch(adapter, store, parent)
    assert_retained(source, published, parent, child, result)
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^published} = finish(adapter, store, source, published, result, 1106)
    assert {:ok, ^published} = accept(adapter, store, source, published, saved.version, 1107)

    for record <- [pending, published, source] do
      assert {:ok, bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    {source, published, pending, completion, usage}
  end

  defp assert_retained(source, published, parent, child, result) do
    assert source.state == :unknown and source.phase == :uncertain
    assert source.active_branch == child.id and source.operation == :branch
    assert source.branch_children == %{child.id => false}
    assert source.native_branch_history == %{child.id => result.proof}

    assert source.observed_machine == result.source and
             source.created_machine == parent.created_machine

    assert published.state == :unknown and published.branch.state == :unknown
    assert published.operation == :branch_child and published.phase == :uncertain
    assert published.created_machine == nil and published.observed_machine == nil
    assert published.absence_at_ms == nil and published.reservation == child.reservation
    assert published.branch.native_authority.completion == nil
    assert published.branch.native_authority.collected_publication.proof == result.proof
  end

  def reject_crossed(adapter, store) do
    {parent, child, completion, usage} = prepare(adapter, store, false)
    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1103)
    source = fetch(adapter, store, parent)
    result = result(pending, completion)

    for invalid <- [
          %{result | version: result.version + 1},
          %{result | platform: "linux"},
          %{result | proof: completion.completion},
          %{result | source: child.branch.source_machine},
          %{result | source: %{result.source | memory_mb: result.source.memory_mb + 1}},
          %{
            result
            | source: %{
                result.source
                | backend_identity: %{result.source.backend_identity | pid_identity: [999, 999]}
              }
          },
          %{
            result
            | source: %{
                result.source
                | backend_identity: %{result.source.backend_identity | transition: nil}
              }
          }
        ] do
      assert {:error, _} = finish(adapter, store, source, pending, invalid, 1104)
      assert fetch(adapter, store, source) == source and fetch(adapter, store, pending) == pending
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:error, _} =
             NativeUnbootedBranchDisposalContract.resolve(
               adapter,
               store,
               source,
               pending,
               completion,
               1104
             )

    assert {:ok, _} = finish(adapter, store, source, pending, result, 1105)
  end

  def complete_partial(adapter, store) do
    {parent, child, _, completion, _} = complete(adapter, store, true)

    assert {:ok, pending} =
             NativePartialBranchCollectionContract.accept(
               adapter,
               store,
               parent,
               child,
               child.version,
               1110
             )

    parent = fetch(adapter, store, parent)
    result = NativePartialBranchCollectionContract.result(pending)

    proof =
      result.proof
      |> PartialBranchCollection.to_wire()
      |> Map.put(
        "publication_sha256",
        BranchCanonical.digest(
          BranchCanonical.ordered(completion.completion.publication, :publication)
        )
      )

    proof = Map.put(proof, "proof_sha256", PartialBranchCollection.proof_digest(proof))
    {:ok, proof} = PartialBranchCollection.from_wire(proof)

    assert {:error, _} =
             NativePartialBranchCollectionContract.finish(
               adapter,
               store,
               parent,
               pending,
               result,
               1111
             )

    assert {:ok, collected} =
             NativePartialBranchCollectionContract.finish(
               adapter,
               store,
               parent,
               pending,
               %{result | proof: proof},
               1111
             )

    parent = fetch(adapter, store, parent)

    assert {:ok, disposing} =
             NativePartialBranchDisposalContract.accept(
               adapter,
               store,
               parent,
               collected,
               collected.version,
               1112
             )

    parent = fetch(adapter, store, parent)

    metadata = %{
      publication: completion.completion.publication,
      release: nil,
      source: completion.source
    }

    result = NativePartialBranchDisposalContract.result(disposing, metadata)

    assert {:ok, disposed} =
             NativePartialBranchDisposalContract.resolve(
               adapter,
               store,
               parent,
               disposing,
               result,
               1113
             )

    assert fetch(adapter, store, parent).native_branch_history ==
             parent.native_branch_history

    assert disposed.branch.state == :disposed
    assert {:ok, bytes} = Codec.encode(disposed)
    assert {:ok, ^disposed} = Codec.decode(bytes)
  end

  def publish_after_collection(adapter, store) do
    {parent, child, metadata, usage} =
      NativePartialBranchDisposalContract.prepare(adapter, store, :held)

    assert {:ok, pending} = accept(adapter, store, parent, child, child.version, 1110)
    parent = fetch(adapter, store, parent)
    {:ok, proof} = BranchPublication.from_wire(metadata.publication)

    result = %NativeCollectedBranchPublicationResult{
      version: pending.version,
      proof: proof,
      source: metadata.source,
      platform: "macos"
    }

    assert {:ok, published} = finish(adapter, store, parent, pending, result, 1111)

    assert published.branch.native_authority.partial_collection ==
             child.branch.native_authority.partial_collection

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
  end
end
