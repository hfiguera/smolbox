defmodule SmolBox.MemoryStoreTest do
  use SmolBox.Store.Contract, async: true

  alias SmolBox.Error
  alias SmolBox.Store.{Contract, Memory}

  setup do
    store = start_supervised!(Memory)
    %{adapter: Memory, store: store}
  end

  test "memory mode is explicitly ephemeral and unavailable stores never become empty snapshots",
       %{store: store} do
    assert {:ok, %{durable: false, schema: 1, atomic: true}} = Memory.capabilities(store)
    assert {:ok, _, :inserted} = Memory.accept(store, Contract.record(), 10)
    GenServer.stop(store)

    assert {:error, %Error{category: :store, evidence: :dispatch_uncertain}} =
             Memory.fetch(store, {"contract", "one"})

    fresh = start_supervised!(Memory, id: :fresh)
    assert {:error, %Error{category: :not_found}} = Memory.fetch(fresh, {"contract", "one"})
  end

  test "record and byte limits reject admission without losing existing identities" do
    bounded = start_supervised!({Memory, max_records: 1}, id: :bounded)
    assert {:ok, _, :inserted} = Memory.accept(bounded, Contract.record(), 10)

    assert {:error, %Error{category: :admission_exhausted}} =
             Memory.accept(bounded, Contract.record("two"), 10)

    tiny = start_supervised!({Memory, max_bytes: 1}, id: :tiny)

    assert {:error, %Error{category: :admission_exhausted}} =
             Memory.accept(tiny, Contract.record(), 10)

    assert {:error, %Error{category: :not_found}} = Memory.fetch(tiny, {"contract", "one"})
    assert {:error, _} = Memory.start_link(max_records: 10_001)
    assert {:error, _} = Memory.start_link(unknown: 1)
  end

  test "expired worker ownership fences a still-live execution claim", %{store: store} do
    record = Contract.record()
    key = SmolBox.Execution.key(record)
    {:ok, _, :inserted} = Memory.accept(store, record, 1)
    {:ok, first} = Memory.claim_worker(store, "worker", "owner", 1000, 1000)
    {:ok, renewed} = Memory.claim_worker(store, "worker", "owner", 1100, 1000)
    assert renewed.generation == first.generation
    {:ok, claim} = Memory.claim(store, key, "owner", 1100, 10_000)

    {:ok, reserved} =
      Memory.reserve(
        store,
        key,
        Contract.guard(claim),
        {"worker", "sbx-one", Contract.capacity()},
        1200
      )

    assert {:error, %Error{category: :stale_claim}} =
             Memory.write(store, key, Contract.guard(reserved), [state: :ready], 2100)

    {:ok, next} = Memory.claim_worker(store, "worker", "owner", 2100, 1000)
    assert next.generation == first.generation + 1

    assert {:error, %Error{category: :stale_claim}} =
             Memory.write(store, key, Contract.guard(reserved), [state: :ready], 2200)

    {:ok, refreshed} = Memory.claim(store, key, "owner", 2200, 10_000)
    assert refreshed.worker_generation == next.generation

    assert {:ok, _ready} =
             Memory.write(store, key, Contract.guard(refreshed), [state: :ready], 2300)
  end

  test "invalid store operations fail without accepting forged work", %{store: store} do
    record = Contract.record()
    assert {:error, _} = Memory.accept(store, %{record | version: 2}, 10)
    assert {:error, _} = Memory.accept(store, record, 0)
    assert {:error, _} = Memory.claim_worker(store, "invalid/worker", "owner", 1000, 1000)
    assert {:error, _} = Memory.claim_worker(store, "worker", "owner", 1000, 0)
    assert {:error, _} = Memory.due(store, 1000, :invalid, 10)
    assert {:error, _} = Memory.claim(store, {"contract", "missing"}, "owner", 1000, 1000)
    {:ok, _, :inserted} = Memory.accept(store, record, 10)
    assert {:error, _} = Memory.write(store, {"contract", "one"}, %{}, [], 1000)
    assert {:error, _} = Memory.cancel(store, {"contract", "one"}, -1)
  end
end
