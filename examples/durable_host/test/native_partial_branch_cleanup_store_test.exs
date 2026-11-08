defmodule SmolBox.DurableHost.NativePartialBranchCleanupStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Embedded.NativePartialBranchDisposalResult
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    NativePartialBranchCleanupContract,
    NativePartialBranchDisposalContract
  }

  alias NativePartialBranchCleanupContract, as: Cleanup

  setup do
    partition =
      "partial-cleanup-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for mode <- [:held, :pre_release, :initial_release, :explicit_release] do
    test "#{mode} persists exact cleanup and resolves both encrypted records and ordinary capacity",
         %{store: store} do
      {_, child, pending, _, _} = Cleanup.complete(Store, store, unquote(mode))

      for record <- [pending, child] do
        assert {:ok, <<"smolbox-record-v48", 0, _::binary>> = bytes} = Codec.encode(record)
        assert {:ok, ^record} = Codec.decode(bytes)
      end
    end
  end

  for mode <- [:held, :initial_release] do
    test "#{mode} deterministic acceptance/completion rollback preserves encrypted records and projections",
         %{store: store} do
      {parent, child, metadata, usage} = Cleanup.prepare(Store, store, unquote(mode))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Cleanup.accept(Store, store, parent, child, child.version, 1401)

                 {:error, :modeled_rollback}
               end)

      assert Cleanup.fetch(Store, store, parent) == parent
      assert Cleanup.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, pending} = Cleanup.accept(Store, store, parent, child, child.version, 1401)
      source = Cleanup.fetch(Store, store, parent)
      result = Cleanup.result(pending, metadata)

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Cleanup.resolve(Store, store, source, pending, result, 1402)
                 {:error, :modeled_rollback}
               end)

      assert Cleanup.fetch(Store, store, parent) == source
      assert Cleanup.fetch(Store, store, child) == pending
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, _} = Cleanup.resolve(Store, store, source, pending, result, 1403)
    end
  end

  test "stale child result retains both records original request and full usage", %{store: store} do
    {parent, child, metadata, usage} = Cleanup.prepare(Store, store, :held)
    assert {:ok, pending} = Cleanup.accept(Store, store, parent, child, child.version, 1401)
    source = Cleanup.fetch(Store, store, parent)
    result = Cleanup.result(pending, metadata)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1402, 10_000])

    assert {:error, _} = Cleanup.resolve(Store, store, source, current, result, 1403)
    assert Cleanup.fetch(Store, store, child) == current
    assert Cleanup.fetch(Store, store, parent) == source
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             Cleanup.resolve(
               Store,
               store,
               source,
               current,
               %{result | version: current.version},
               1404
             )
  end

  test "ordinary disposal cannot consume cleanup even with matching common proof and source", %{
    store: store
  } do
    {parent, child, metadata, usage} = Cleanup.prepare(Store, store, :explicit_release)
    assert {:ok, pending} = Cleanup.accept(Store, store, parent, child, child.version, 1401)
    source = Cleanup.fetch(Store, store, parent)
    common = NativePartialBranchDisposalContract.result(pending, metadata, "resolved_absent")
    refute NativePartialBranchDisposalResult.bound?(common, source, pending)
    assert {:error, _} = Cleanup.resolve(Store, store, source, pending, common, 1402)
    assert Cleanup.fetch(Store, store, parent) == source
    assert Cleanup.fetch(Store, store, child) == pending
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             Cleanup.resolve(
               Store,
               store,
               source,
               pending,
               Cleanup.result(pending, metadata),
               1403
             )
  end

  test "stale source acceptance and wrong platform cannot mutate encrypted authority", %{
    store: store
  } do
    {parent, child, _, usage} = Cleanup.prepare(Store, store, :held)
    assert {:error, _} = Cleanup.accept(Store, store, parent, child, child.version, 1401, "linux")

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1401, 10_000])

    assert {:error, _} = Cleanup.accept(Store, store, parent, child, child.version, 1402)
    assert Cleanup.fetch(Store, store, parent) == current
    assert Cleanup.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
  end

  test "reader marker is present without enabling native branch admission", %{store: store} do
    assert {:ok, %{native_partial_branch_cleanups: 1} = caps} = Store.capabilities(store)
    refute Map.has_key?(caps, :native_branches)
  end
end
