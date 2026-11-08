defmodule SmolBox.DurableHost.NativePartialBranchBackingStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.NativePartialBranchBackingContract, as: Contract

  setup do
    partition =
      "partial-backing-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for material <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ~w(deleted resolved_absent) do
    test "#{material} #{provenance} closes only accepted original backing and preserves all prior histories",
         %{store: store} do
      Contract.completed(Store, store, unquote(material), unquote(provenance))
    end
  end

  for material <- [:held, :initial_release] do
    test "#{material} modeled rollback preserves both encrypted records and capacity at acceptance and completion",
         %{store: store} do
      {source, child, usage} = Contract.prepare(Store, store, unquote(material))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Contract.accept(Store, store, source, child, 1312)
                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, source) == source
      assert Contract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, source.worker_id)
      assert {:ok, pending} = Contract.accept(Store, store, source, child, 1312)
      parent = Contract.fetch(Store, store, source)
      proof = Contract.proof(pending.branch.native_authority.backing.request)

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Contract.complete_proof(Store, store, parent, pending, proof, 1313)

                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, source) == parent
      assert Contract.fetch(Store, store, child) == pending
      assert {:ok, ^usage} = Store.usage(store, source.worker_id)
      assert {:ok, _} = Contract.complete_proof(Store, store, parent, pending, proof, 1314)
    end
  end

  test "stale source guards reject before admission and before acknowledged closure", %{
    store: store
  } do
    {source, child, usage} = Contract.prepare(Store, store, :held)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(source), "owner", 1312, 10_000])

    assert {:error, _} = Contract.accept(Store, store, source, child, 1313)
    assert {:ok, pending} = Contract.accept(Store, store, current, child, 1313)
    parent = Contract.fetch(Store, store, source)
    proof = Contract.proof(pending.branch.native_authority.backing.request)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1314, 10_000])

    assert {:error, _} = Contract.complete_proof(Store, store, parent, pending, proof, 1315)
    assert Contract.fetch(Store, store, child) == pending
    assert {:ok, ^usage} = Store.usage(store, source.worker_id)
    assert {:ok, _} = Contract.complete_proof(Store, store, current, pending, proof, 1315)
    assert {:ok, %{native_partial_branch_backings: 1} = caps} = Store.capabilities(store)
    assert caps.native_branches == 1
  end

  test "claims preserve accepted intent until only its exact typed acknowledgement closes backing",
       %{store: store} do
    {source, child, usage} = Contract.prepare(Store, store, :initial_release)
    assert {:ok, pending} = Contract.accept(Store, store, source, child, 1312)
    source = Contract.fetch(Store, store, source)
    saved = pending.branch.native_authority.backing

    assert {:ok, claimed} =
             Store.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1313, 10_000])

    assert {:ok, ^claimed} = Contract.accept(Store, store, source, claimed, 1314)
    assert claimed.branch.native_authority.backing == saved
    assert {:ok, ^usage} = Store.usage(store, source.worker_id)

    assert {:ok, _} =
             Contract.complete_proof(
               Store,
               store,
               source,
               claimed,
               Contract.proof(saved.request),
               1315
             )
  end
end
