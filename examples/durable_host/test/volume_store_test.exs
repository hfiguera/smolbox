defmodule SmolBox.DurableHost.VolumeStoreTest do
  use SmolBox.Store.VolumeContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.VolumeContract

  setup do
    partition = "volume-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "transaction rollback keeps volume and attachment unchanged", %{store: store} do
    v = VolumeContract.ready(Store, store)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Store.machine(store, :accept, [
                          VolumeContract.machine("rollback"),
                          10
                        ])

               {:error, :injected}
             end)

    assert {:ok, ^v} = Store.volume_fetch(store, SmolBox.Volume.key(v))

    assert {:error, %{category: :not_found}} =
             Store.machine(store, :fetch, [{"contract", "rollback"}])
  end
end
