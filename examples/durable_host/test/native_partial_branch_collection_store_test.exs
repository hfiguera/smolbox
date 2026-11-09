defmodule SmolBox.DurableHost.NativePartialBranchCollectionStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, NativePartialBranchCollectionContract}

  alias NativePartialBranchCollectionContract, as: Contract

  setup do
    partition =
      "partial-collection-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for hold <- [true, false] do
    test "held=#{hold} encrypted collection preserves unknown creation and every reservation", %{
      store: store
    } do
      {_, child, _, pending} = Contract.complete(Store, store, unquote(hold))

      for record <- [pending, child] do
        assert {:ok, <<"smolbox-record-v44", 0, _::binary>> = bytes} = Codec.encode(record)
        assert {:ok, ^record} = Codec.decode(bytes)
      end
    end

    test "held=#{hold} request and acknowledgement roll back together with both projections", %{
      store: store
    } do
      {parent, child, _, usage} = Contract.prepare(Store, store, unquote(hold))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Contract.accept(Store, store, parent, child, child.version, 1103)

                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == parent
      assert Contract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1103)
      current = Contract.fetch(Store, store, parent)
      result = Contract.result(pending)

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Contract.finish(Store, store, current, pending, result, 1104)
                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == current
      assert Contract.fetch(Store, store, child) == pending
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, completed} = Contract.finish(Store, store, current, pending, result, 1105)
      assert Contract.fetch(Store, store, completed) == completed
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end
  end

  test "stale child result cannot acknowledge the encrypted accepted request", %{store: store} do
    {parent, child, _, usage} = Contract.prepare(Store, store, true)
    assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1103)
    current = Contract.fetch(Store, store, parent)
    result = Contract.result(pending)

    assert {:ok, fresh} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1104, 10_000])

    assert {:error, _} = Contract.finish(Store, store, current, fresh, result, 1105)
    assert Contract.fetch(Store, store, parent) == current
    assert Contract.fetch(Store, store, child) == fresh
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, collected} =
             Contract.finish(Store, store, current, fresh, Contract.result(fresh), 1105)

    assert collected.branch.native_authority.partial_collection.request ==
             pending.branch.native_authority.partial_collection.request
  end

  test "stale source guard rejects acceptance without changing either encrypted record", %{
    store: store
  } do
    {parent, child, _, usage} = Contract.prepare(Store, store, true)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1103, 10_000])

    assert {:error, _} = Contract.accept(Store, store, parent, child, child.version, 1104)
    assert Contract.fetch(Store, store, parent) == current
    assert Contract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Contract.accept(Store, store, current, child, child.version, 1104)

    assert {:ok, %{native_partial_branch_collections: 1} = capabilities} =
             Store.capabilities(store)

    refute Map.has_key?(capabilities, :native_branches)
  end
end
