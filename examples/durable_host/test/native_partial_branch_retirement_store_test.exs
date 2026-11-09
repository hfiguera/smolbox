defmodule SmolBox.DurableHost.NativePartialBranchRetirementStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.NativePartialBranchRetirementContract, as: Contract

  setup do
    partition =
      "partial-retirement-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ~w(deleted resolved_absent) do
    test "#{mode} #{provenance} retires the dependency atomically while retaining backing", %{
      store: store
    } do
      Contract.complete(Store, store, unquote(mode), unquote(provenance))
    end
  end

  for mode <- [:held, :initial_release] do
    test "#{mode} modeled rollback preserves both encrypted records and accounting", %{
      store: store
    } do
      {parent, child, proof, usage} = Contract.prepare(Store, store, unquote(mode))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Contract.advance(Store, store, parent, child, proof, 1201)
                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == parent
      assert Contract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, _} = Contract.advance(Store, store, parent, child, proof, 1202)
    end
  end

  test "stale source guard retains dependency and backing", %{store: store} do
    {parent, child, proof, usage} = Contract.prepare(Store, store, :held)

    assert {:ok, source} =
             Store.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1201, 10_000])

    assert {:error, _} = Contract.advance(Store, store, parent, child, proof, 1202)
    assert Contract.fetch(Store, store, parent) == source
    assert Contract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Contract.advance(Store, store, source, child, proof, 1202)
    assert {:ok, %{native_partial_branch_retirements: 1} = caps} = Store.capabilities(store)
    assert caps.native_branches == 1
  end

  test "stale child proof rejects and fresh observation remains required", %{store: store} do
    {parent, child, proof, usage} = Contract.prepare(Store, store, :initial_release)

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1201, 10_000])

    assert {:error, _} = Contract.advance(Store, store, parent, current, proof, 1202)
    assert Contract.fetch(Store, store, parent) == parent
    assert Contract.fetch(Store, store, child) == current
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             Contract.advance(Store, store, parent, current, Contract.proof(current), 1202)
  end
end
