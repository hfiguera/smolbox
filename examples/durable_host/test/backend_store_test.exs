defmodule SmolBox.DurableHost.BackendStoreTest do
  use SmolBox.Store.BackendContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.{BackendContract, Codec, Contract}

  alias SmolBox.Execution

  setup do
    partition = "native-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "failed transactions roll back enrollment and native intent with its projections", %{
    store: store
  } do
    native = BackendContract.domain_binding()

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
               {:error, :injected}
             end)

    assert %{rows: [[0]]} =
             Database.query(
               store,
               "SELECT count(*) FROM smolbox_backend_bindings WHERE partition=$1",
               [store.partition]
             )

    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = BackendContract.pending(Store, store, "rollback")
    intent = BackendContract.assignment(record, "native-rollback")

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = BackendContract.reserve(Store, store, record, intent)
               {:error, :injected}
             end)

    assert {:ok, ^record} = Store.fetch(store, Execution.key(record))
    assert {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(store, "worker")

    assert {:error, %{category: :not_found}} =
             Store.find_machine(store, "worker", "native-rollback")

    assert {:ok, _} = BackendContract.reserve(Store, store, record, intent)
    assert {:ok, %{slots: 1}} = Store.usage(store, "worker")

    assert {:error, _} =
             Store.write(store, Execution.key(record), Contract.guard(record), [], 1300)
  end

  test "missing binding storage fails closed instead of admitting HTTP", %{store: store} do
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = BackendContract.pending(Store, store, "missing-binding")

    assert {:error, :restore} =
             Repo.transact(fn ->
               Database.query(
                 store,
                 "ALTER TABLE smolbox_backend_bindings RENAME TO smolbox_hidden_bindings",
                 []
               )

               assert {:error, %{category: :store}} = Store.capabilities(store)

               assert {:error, %{category: :store}} =
                        BackendContract.reserve(Store, store, record, nil)

               {:error, :restore}
             end)

    assert {:ok, ^record} = Store.fetch(store, Execution.key(record))
    assert {:ok, %{slots: 0}} = Store.usage(store, "worker")
  end

  test "losing a binding row cannot reinterpret native assignments as HTTP", %{store: store} do
    native = BackendContract.domain_binding()
    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = BackendContract.pending(Store, store, "owned")
    intent = BackendContract.assignment(record, "native-owned")
    assert {:ok, _} = BackendContract.reserve(Store, store, record, intent)

    Database.query(store, "DELETE FROM smolbox_backend_bindings WHERE partition=$1", [
      store.partition
    ])

    assert {:error, %{category: :identity_conflict}} = Store.bind_backend(store, "worker", :http)

    assert {:error, _} =
             Store.bind_backend(store, "worker", BackendContract.domain_binding("worker", "d"))

    pending = BackendContract.pending(Store, store, "other")
    assert {:error, _} = BackendContract.reserve(Store, store, pending, nil)
    assert {:ok, ^pending} = Store.fetch(store, Execution.key(pending))

    assert {:error, %{category: :identity_conflict}} =
             Store.bind_backend(
               store,
               "another-pool",
               BackendContract.domain_binding("another-pool")
             )

    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
  end

  test "enrollment authenticates all tombstone pages, including a conflicting last page", %{
    store: store
  } do
    native = BackendContract.domain_binding()
    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)

    records =
      for index <- 0..100,
          do: released(store, "page-" <> String.pad_leading(Integer.to_string(index), 3, "0"))

    assert {:ok, %{slots: 0}} = Store.usage(store, "worker")
    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)

    # Inject authenticated inconsistent history beyond page one. Enrollment must
    # discover it even though operational maintenance omits these tombstones.
    last = List.last(records)
    changed = put_in(last.backend_assignment.binding.generation, String.duplicate("d", 32))
    assert {:ok, _} = Database.write(store, changed)
    assert {:error, %{category: :identity_conflict}} = Store.bind_backend(store, "worker", native)
  end

  test "a fresh BEAM reads the saved native intent, binding and reservation", %{store: store} do
    native = BackendContract.domain_binding()
    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = BackendContract.pending(Store, store, "fresh")
    intent = BackendContract.assignment(record, "native-fresh")
    assert {:ok, reserved} = BackendContract.reserve(Store, store, record, intent)
    assert {:ok, bytes} = Codec.encode(reserved)

    directory =
      Path.join(
        System.tmp_dir!(),
        "smolbox-store-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    packet = Path.join(directory, "input.etf")
    File.write!(packet, :erlang.term_to_binary({store.partition, store.key, bytes}), [:exclusive])
    File.chmod!(packet, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    assert {"fresh-native-store\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", fresh_reader(), packet],
               stderr_to_stdout: true
             )
  end

  test "assignment recovery authenticates rows with missing or displaced worker projections", %{
    store: store
  } do
    native = BackendContract.domain_binding()
    assert {:ok, ^native} = Store.bind_backend(store, "worker", native)
    assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
    record = BackendContract.pending(Store, store, "projection")
    intent = BackendContract.assignment(record, "native-projection")
    assert {:ok, _} = BackendContract.reserve(Store, store, record, intent)

    for projection <- [nil, "displaced-worker"] do
      Database.query(
        store,
        "UPDATE smolbox_executions SET worker_id=$1 WHERE partition=$2 AND scope=$3 AND execution_id=$4",
        [projection, store.partition, record.scope, record.id]
      )

      assert {:error, %{category: :store}} = Store.backend_assignments(store, "worker", nil, 1)
      assert {:error, %{category: :store}} = Store.backend_assignments(store, "other", nil, 1)
    end
  end

  test "assignment recovery cannot turn an unreadable payload into an empty page", %{store: store} do
    record = BackendContract.pending(Store, store, "unreadable")

    Database.query(
      store,
      "UPDATE smolbox_executions SET payload=$1 WHERE partition=$2 AND scope=$3 AND execution_id=$4",
      [<<0>>, store.partition, record.scope, record.id]
    )

    assert {:error, %{category: :store}} = Store.backend_assignments(store, "worker", nil, 1)
  end

  defp released(store, id) do
    record = BackendContract.pending(Store, store, id)
    intent = BackendContract.assignment(record, "native-" <> id)
    assert {:ok, reserved} = BackendContract.reserve(Store, store, record, intent)

    assert {:ok, cleaned} =
             Store.write(
               store,
               Execution.key(record),
               Contract.guard(reserved),
               [state: :failed, cleanup: :complete, absence_at_ms: 1300],
               1300
             )

    assert {:ok, released} =
             Store.release(store, Execution.key(record), Contract.guard(cleaned), 1400)

    released
  end

  defp fresh_reader do
    """
    [path] = System.argv()
    {partition, key, bytes} = :erlang.binary_to_term(File.read!(path), [:safe])
    app = :smolbox_durable_host
    repo = SmolBox.DurableHost.Repo
    config = Config.Reader.read!("config/runtime.exs", env: :test)
    Application.put_env(app, repo, Keyword.merge(config[app][repo], pool_size: 1, log: false))
    {:ok, _} = Application.ensure_all_started(:smolbox_durable_host)
    {:ok, expected} = SmolBox.Store.Codec.decode(bytes)
    {:ok, store} = SmolBox.DurableHost.Store.new(SmolBox.DurableHost.Repo, partition, key)
    {:ok, found} = SmolBox.DurableHost.Store.fetch(store, SmolBox.Execution.key(expected))
    true = found == expected
    binding = expected.backend_assignment.binding
    {:ok, ^binding} = SmolBox.DurableHost.Store.bind_backend(store, "worker", binding)
    {:ok, %{slots: 1}} = SmolBox.DurableHost.Store.usage(store, "worker")
    {:ok, [^expected], nil} = SmolBox.DurableHost.Store.backend_assignments(store, "worker", nil, 1)
    IO.puts("fresh-native-store")
    """
  end
end
