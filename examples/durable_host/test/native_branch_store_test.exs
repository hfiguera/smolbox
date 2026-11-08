defmodule SmolBox.DurableHost.NativeBranchStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{NativeBranchContract, NativeBranchReleaseContract}

  setup do
    partition =
      "native-branch-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for uncertain <- [false, true] do
    test "native held release uncertain=#{uncertain} pairs source child and retained projections",
         %{store: store} do
      NativeBranchReleaseContract.completed(Store, store, unquote(uncertain))
    end
  end

  test "held release intent and completion each roll back both records and projections", %{
    store: store
  } do
    {parent, child, _, usage} = NativeBranchContract.complete(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Store.machine(store, :branch_release, [
                          ManagedMachine.key(child),
                          child.version,
                          1200
                        ])

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^child} = Store.machine(store, :fetch, [ManagedMachine.key(child)])

    assert {:ok, pending} =
             Store.machine(store, :branch_release, [
               ManagedMachine.key(child),
               child.version,
               1200
             ])

    assert {:ok, pending} =
             Store.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1200, 10_000])

    assert {:ok, sent} =
             NativeBranchReleaseContract.advance(Store, store, pending, :dispatching, 1201)

    assert {:ok, parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    result = NativeBranchReleaseContract.result(parent, sent)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchReleaseContract.advance(
                          Store,
                          store,
                          sent,
                          {:native_complete, result},
                          1202
                        )

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^sent} = Store.machine(store, :fetch, [ManagedMachine.key(sent)])
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
  end

  for hold <- [true, false] do
    test "native held=#{hold} explicit kept resolution binds historical completion and current observations",
         %{store: store} do
      NativeBranchContract.resolve_completed(Store, store, unquote(hold))
    end

    test "native held=#{hold} completion retains exact source child and backing atomically", %{
      store: store
    } do
      NativeBranchContract.complete(Store, store, unquote(hold))
    end
  end

  test "source publication child completion and projections roll back together", %{store: store} do
    {parent, child, result} = NativeBranchContract.prepare(Store, store, false)

    assert {:ok, sent} =
             NativeBranchContract.advance(
               Store,
               store,
               parent,
               child,
               :accepted,
               :dispatching,
               1101
             )

    assert {:ok, parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, usage} = Store.usage(store, parent.worker_id)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchContract.advance(
                          Store,
                          store,
                          parent,
                          child,
                          :dispatching,
                          {:native_complete, result},
                          1102
                        )

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^sent} = Store.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativeBranchContract.advance(
               Store,
               store,
               parent,
               child,
               :dispatching,
               {:native_complete, result},
               1102
             )
  end
end
