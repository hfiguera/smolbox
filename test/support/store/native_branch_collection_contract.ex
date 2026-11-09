defmodule SmolBox.Store.NativeBranchCollectionContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{BranchDeletionCollection, NativeBranchDeletionAction}
  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    NativeBranchDeletionActionContract,
    NativeBranchDeletionContract,
    NativeReleasedBranchCleanupContract,
    NativeReleasedBranchContinuationContract,
    NativeReleasedBranchDeletionContract
  }

  defdelegate proof(request), to: NativeBranchDeletionActionContract

  def accept(adapter, store, child, now),
    do: NativeBranchDeletionActionContract.accept(adapter, store, child, :collect, now)

  def finish(adapter, store, child, proof, now),
    do: NativeBranchDeletionActionContract.finish(adapter, store, child, :collect, proof, now)

  def complete(adapter, store, mode) do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store, mode)
    assert {:ok, before_bytes} = Codec.encode(child)
    assert {:ok, pending} = accept(adapter, store, child, 1303)
    saved = pending.branch.native_authority.delete_collection
    assert saved.version == child.version and saved.delete_version == elem(child.last_request, 1)
    assert NativeBranchDeletionAction.valid?(saved, pending.branch.native_authority, :collect)
    assert {:ok, ^pending} = accept(adapter, store, pending, 1304)
    assert {:ok, ^usage} = adapter.usage(store, child.worker_id)
    roundtrip(pending)
    evidence = proof(saved.request)

    for invalid <- [
          :absent,
          BranchDeletionCollection.to_wire(evidence),
          %{evidence | collection_sha256: String.duplicate("0", 64)}
        ] do
      assert {:error, _} = finish(adapter, store, pending, invalid, 1304)
      assert NativeBranchDeletionContract.fetch(adapter, store, pending) == pending
    end

    for action <- [:continue, :cleanup] do
      assert {:error, _} =
               NativeBranchDeletionActionContract.finish(
                 adapter,
                 store,
                 pending,
                 action,
                 evidence,
                 1304
               )
    end

    assert {:error, _} =
             NativeBranchDeletionContract.resolve(adapter, store, pending, evidence, 1304)

    assert {:ok, fresh} =
             adapter.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1304, 10_000])

    assert {:error, _} = finish(adapter, store, pending, evidence, 1305)
    assert {:ok, ^fresh} = accept(adapter, store, fresh, 1305)
    assert fresh.branch.native_authority.delete_collection == saved
    assert {:ok, collected} = finish(adapter, store, fresh, evidence, 1305)
    assert collected.branch.native_authority.delete_collection.proof == evidence

    assert Map.drop(Map.from_struct(collected), [:branch, :updated_at_ms, :version]) ==
             Map.drop(Map.from_struct(fresh), [:branch, :updated_at_ms, :version])

    assert %{collected.branch | native_authority: fresh.branch.native_authority} == fresh.branch
    assert collected.state == :unknown and collected.operation == :delete

    assert collected.reservation == child.reservation and
             collected.reserved_ports == child.reserved_ports

    assert {:ok, ^usage} = adapter.usage(store, child.worker_id)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    assert parent.branch_children[child.id] == false
    refute NativeBranchDeletionAction.acknowledged?(collected.branch.native_authority)

    assert {:error, _} =
             ManagedMachine.update(
               collected,
               %{state: :deleted, operation: nil, phase: nil, reservation: nil},
               1306
             )

    assert {:ok, ^collected} = finish(adapter, store, collected, evidence, 1306)
    roundtrip(collected)
    # Earlier records still roundtrip to their exact selective envelope bytes.
    assert {:ok, ^child} = Codec.decode(before_bytes)
    assert {:ok, ^before_bytes} = Codec.encode(child)
    {parent, collected, evidence, usage}
  end

  def continue(adapter, store, mode) do
    {parent, collected, evidence, usage} = complete(adapter, store, mode)

    assert {:ok, pending} =
             NativeBranchDeletionActionContract.accept(adapter, store, collected, :continue, 1307)

    request = pending.branch.native_authority.delete_continuation.request

    proof =
      if mode == :held,
        do: NativeBranchDeletionActionContract.proof(request),
        else: NativeReleasedBranchContinuationContract.proof(request)

    assert {:ok, gone} =
             NativeBranchDeletionActionContract.finish(
               adapter,
               store,
               pending,
               :continue,
               proof,
               1308
             )

    assert gone.state == :deleted and gone.reservation == nil

    assert gone.branch.native_authority.delete_collection ==
             collected.branch.native_authority.delete_collection

    assert gone.branch.native_authority.delete_collection.proof == evidence

    expected =
      Map.merge(usage, Profile.resources(collected.spec.profile), fn _, a, b -> a - b end)

    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    roundtrip(gone)
    {parent, gone}
  end

  def interleaved(adapter, store, mode, route) do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store, mode)
    assert {:ok, pending} = accept(adapter, store, child, 1303)
    collection = pending.branch.native_authority.delete_collection
    assert {:ok, accepted} = accept_final(adapter, store, pending, route)

    saved =
      if route == :resolve,
        do: accepted.branch.native_authority.deletion,
        else: NativeBranchDeletionActionContract.saved(accepted, route)

    evidence = final_proof(saved.request, mode, route)

    result =
      if route == :resolve,
        do: NativeBranchDeletionContract.resolve(adapter, store, accepted, evidence, 1305),
        else:
          NativeBranchDeletionActionContract.finish(
            adapter,
            store,
            accepted,
            route,
            evidence,
            1305
          )

    assert {:ok, gone} = result
    assert gone.state == :deleted and gone.reservation == nil
    assert gone.branch.native_authority.delete_collection == collection
    assert collection.proof == nil
    assert {:error, _} = accept(adapter, store, gone, 1306)
    assert {:error, _} = finish(adapter, store, gone, proof(collection.request), 1306)
    assert NativeBranchDeletionContract.fetch(adapter, store, gone) == gone
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    roundtrip(gone)
  end

  defp accept_final(adapter, store, child, :resolve),
    do: NativeBranchDeletionContract.accept(adapter, store, child, 1304)

  defp accept_final(adapter, store, child, action),
    do: NativeBranchDeletionActionContract.accept(adapter, store, child, action, 1304)

  defp final_proof(request, :held, :resolve), do: NativeBranchDeletionContract.proof(request)
  defp final_proof(request, :held, _), do: NativeBranchDeletionActionContract.proof(request)
  defp final_proof(request, _, :resolve), do: NativeReleasedBranchDeletionContract.proof(request)

  defp final_proof(request, _, :continue),
    do: NativeReleasedBranchContinuationContract.proof(request)

  defp final_proof(request, _, :cleanup), do: NativeReleasedBranchCleanupContract.proof(request)

  def roundtrip(record) do
    assert {:ok, <<"smolbox-record-v43\0", body::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 1..42,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")

    assert {:error, _} =
             Codec.decode("smolbox-record-v43\0" <> :erlang.term_to_binary(record, compressed: 9))

    bytes
  end
end
