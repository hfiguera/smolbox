defmodule SmolBox.DurableHost.MachineIndexTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.{Error, Execution}
  alias SmolBox.Store.Contract

  setup do
    partition = "index-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    record = Contract.record()
    {:ok, _, :inserted} = Store.accept(store, record, 1)
    {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 5000)
    {:ok, claimed} = Store.claim(store, Execution.key(record), "owner", 1100, 5000)

    {:ok, reserved} =
      Store.reserve(
        store,
        Execution.key(record),
        Contract.guard(claimed),
        {"worker", "vm", Contract.capacity()},
        1100
      )

    %{store: store, record: reserved}
  end

  test "an incomplete index fails closed and a bounded authenticated backfill restores it", %{
    store: store,
    record: record
  } do
    Database.query(store, "DELETE FROM smolbox_machine_identities WHERE partition=$1", [
      store.partition
    ])

    assert {:error, %Error{category: :store}} = Store.capabilities(store)
    assert {:error, %Error{category: :store}} = Store.find_machine(store, "worker", "vm")
    assert {:error, %Error{category: :store}} = Store.find_machine(store, "worker", "absent")

    assert {:error, %Error{category: :store}} =
             Store.backfill_machine_index(%{store | key: :crypto.strong_rand_bytes(32)})

    assert {:ok, :more} = Store.backfill_machine_index(store)
    assert {:ok, :done} = Store.backfill_machine_index(store)
    assert {:ok, %{durable: true}} = Store.capabilities(store)
    assert {:ok, ^record} = Store.find_machine(store, "worker", "vm")
    assert {:error, %Error{category: :not_found}} = Store.find_machine(store, "worker", "absent")
  end

  test "wrong keys and corrupt assignment projections are never ownership evidence", %{
    store: store,
    record: record
  } do
    assert {:error, %Error{category: :store}} =
             Store.find_machine(%{store | key: :crypto.strong_rand_bytes(32)}, "worker", "vm")

    Database.query(
      store,
      "UPDATE smolbox_machine_identities SET machine_name='foreign' WHERE partition=$1",
      [store.partition]
    )

    assert {:error, %Error{category: :store}} = Store.find_machine(store, "worker", "foreign")
    assert {:ok, ^record} = Store.fetch(store, Execution.key(record))
  end
end
