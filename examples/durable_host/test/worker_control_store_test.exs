defmodule SmolBox.DurableHost.WorkerControlStoreTest do
  use SmolBox.Store.WorkerControlContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}

  setup do
    partition = "drain-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "a failed transaction cannot commit a drain and a missing table is not active admission",
       %{store: store} do
    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = Store.set_worker_mode(store, "worker", :draining, :any, 1000)
               {:error, :injected}
             end)

    assert {:ok, %{mode: :active, version: 0}} = Store.worker_control(store, "worker")

    assert {:error, :restore} =
             Repo.transact(fn ->
               Database.query(
                 store,
                 "ALTER TABLE smolbox_worker_controls RENAME TO smolbox_hidden_controls",
                 []
               )

               assert {:error, %{category: :store}} = Store.worker_control(store, "worker")
               {:error, :restore}
             end)

    assert {:ok, %{mode: :active}} = Store.worker_control(store, "worker")
  end
end
