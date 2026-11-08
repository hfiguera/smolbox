defmodule SmolBox.DurableHost.NativeVolumeStoreTest do
  use SmolBox.Store.NativeVolumeContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.{NativeVolumeContract, VolumeContract}

  alias SmolBox.{ManagedMachine, Volume}

  setup do
    partition =
      "native-volume-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "native attachment rollback preserves proof, indexes and independent disk projection", %{
    store: store
  } do
    volume = NativeVolumeContract.ready(Store, store)
    machine = VolumeContract.machine("rollback")

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, attached} = Store.machine(store, :accept, [machine, 10])
               assert [_] = attached.native_mounts
               assert {:ok, held} = Store.volume_fetch(store, Volume.key(volume))
               assert held.attached_to == ManagedMachine.key(machine)
               {:error, :injected}
             end)

    assert {:ok, ^volume} = Store.volume_fetch(store, Volume.key(volume))

    assert {:error, %{category: :not_found}} =
             Store.machine(store, :fetch, [ManagedMachine.key(machine)])

    assert {:ok, [^volume], nil} =
             Store.backend_assignments(store, volume.worker_id, nil, 10)

    assert {:ok, %{slots: 0, disk_gb: 4}} = Store.usage(store, volume.worker_id)
  end
end
