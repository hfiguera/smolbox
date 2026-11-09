defmodule SmolBox.DurableHost.NativePartialBranchDisposalStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.ManagedMachine

  alias SmolBox.DurableHost.{Database, Repo, Store}

  alias SmolBox.Store.{Codec, NativePartialBranchDisposalContract}

  alias NativePartialBranchDisposalContract, as: Contract

  setup do
    partition =
      "partial-disposal-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ~w(deleted resolved_absent) do
    test "#{mode} #{provenance} atomically retires only ordinary capacity", %{store: store} do
      {_, child, pending, _, _} =
        Contract.complete(Store, store, unquote(mode), unquote(provenance))

      for record <- [pending, child] do
        assert {:ok, <<"smolbox-record-v45", 0, _::binary>> = bytes} = Codec.encode(record)
        assert {:ok, ^record} = Codec.decode(bytes)
      end
    end
  end

  for mode <- [:held, :initial_release] do
    test "#{mode} modeled transaction rollback preserves both encrypted records and projections",
         %{store: store} do
      {parent, child, metadata, usage} = Contract.prepare(Store, store, unquote(mode))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Contract.accept(Store, store, parent, child, child.version, 1105)

                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == parent
      assert Contract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1105)
      source = Contract.fetch(Store, store, parent)
      result = Contract.result(pending, metadata)

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Contract.resolve(Store, store, source, pending, result, 1106)
                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == source
      assert Contract.fetch(Store, store, child) == pending
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, _} = Contract.resolve(Store, store, source, pending, result, 1107)
    end
  end

  test "stale child completion retains the exact encrypted request and collection", %{
    store: store
  } do
    {parent, child, metadata, usage} = Contract.prepare(Store, store, :held)
    assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1105)
    source = Contract.fetch(Store, store, parent)
    result = Contract.result(pending, metadata)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1106, 10_000])

    assert {:error, _} = Contract.resolve(Store, store, source, current, result, 1107)
    assert Contract.fetch(Store, store, parent) == source
    assert Contract.fetch(Store, store, child) == current
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             Contract.resolve(
               Store,
               store,
               source,
               current,
               %{result | version: current.version},
               1107
             )
  end

  test "stale source guard rejects admission and the new reader marker enables no native branches",
       %{store: store} do
    {parent, child, _, usage} = Contract.prepare(Store, store, :held)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1105, 10_000])

    assert {:error, _} = Contract.accept(Store, store, parent, child, child.version, 1106)
    assert Contract.fetch(Store, store, parent) == current
    assert Contract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, %{native_partial_branch_disposals: 1} = capabilities} = Store.capabilities(store)
    refute Map.has_key?(capabilities, :native_branches)
  end
end
