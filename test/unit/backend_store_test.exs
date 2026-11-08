defmodule SmolBox.BackendStoreTest do
  use SmolBox.Store.BackendContract, async: true
  alias SmolBox.Store.{BackendContract, Codec, Contract, Memory, RecordOps}

  alias SmolBox.Execution

  setup do
    %{adapter: SmolBox.Store.Memory, store: start_supervised!(SmolBox.Store.Memory)}
  end

  test "encoded-byte exhaustion rolls back native intent, capacity and assignment index" do
    record = Contract.record("bounded")
    {:ok, expected} = RecordOps.claim(record, nil, "owner", 1100, 10_000)
    {:ok, bytes} = Codec.encode(expected)
    store = start_supervised!({Memory, max_bytes: byte_size(bytes)}, id: :bounded_native)
    assert {:ok, _} = Memory.bind_backend(store, "worker", BackendContract.domain_binding())
    assert {:ok, _} = Memory.claim_worker(store, "worker", "owner", 1000, 10_000)
    claimed = BackendContract.pending(Memory, store, "bounded")
    assert claimed == expected
    intent = BackendContract.assignment(claimed, "native-bounded")

    assert {:error, %{category: :admission_exhausted}} =
             BackendContract.reserve(Memory, store, claimed, intent)

    assert {:ok, ^claimed} = Memory.fetch(store, Execution.key(claimed))
    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(store, "worker")

    assert {:error, %{category: :not_found}} =
             Memory.find_machine(store, "worker", "native-bounded")
  end

  test "native enrollment itself remains bounded by the configured record limit" do
    store = start_supervised!({Memory, max_records: 1}, id: :bounded_bindings)
    native = BackendContract.domain_binding()
    assert {:ok, ^native} = Memory.bind_backend(store, "worker", native)
    assert {:ok, ^native} = Memory.bind_backend(store, "worker", native)

    assert {:error, %{category: :admission_exhausted}} =
             Memory.bind_backend(store, "other", :http)
  end
end
