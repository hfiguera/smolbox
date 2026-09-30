defmodule SmolBox.DurableHost.ExpansionStoreTest do
  use SmolBox.Store.ExpansionContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.ExpansionContract

  setup do
    partition = "growth-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "failed PostgreSQL transaction rolls back both intent and disk accounting", %{store: store} do
    machine = ExpansionContract.stopped(Store, store)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = ExpansionContract.accept(Store, store, machine)
               {:error, :injected}
             end)

    assert {:ok, %{disk_expansions: history}} =
             Store.machine(store, :fetch, [SmolBox.ManagedMachine.key(machine)])

    assert history == %{}
    assert {:ok, %{disk_gb: 2}} = Store.usage(store, "worker")
  end
end
