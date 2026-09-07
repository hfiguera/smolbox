defmodule SmolBox.DurableHost.StoreTest do
  use SmolBox.Store.Contract, async: false

  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Error
  alias SmolBox.Store.Contract

  setup do
    partition = "test-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "records are authenticated and encrypted and cannot move across identities", %{
    store: store
  } do
    record = Contract.record("private", ["echo", "super-secret-fixture"])
    assert {:ok, %{durable: true, atomic: true, schema: 1}} = Store.capabilities(store)
    assert {:ok, _, :inserted} = Store.accept(store, record, 10)

    %{rows: [[payload]]} =
      Database.query(store, "SELECT payload FROM smolbox_executions WHERE partition=$1", [
        store.partition
      ])

    assert :binary.match(payload, "super-secret-fixture") == :nomatch
    refute inspect(store) =~ Base.encode64(store.key)
    assert {:ok, ^record} = Store.fetch(store, {"contract", "private"})

    assert {:error, %Error{category: :store}} =
             Store.fetch(%{store | key: :crypto.strong_rand_bytes(32)}, {"contract", "private"})

    corrupted = <<0>> <> binary_part(payload, 1, byte_size(payload) - 1)

    Database.query(store, "UPDATE smolbox_executions SET payload=$2 WHERE partition=$1", [
      store.partition,
      corrupted
    ])

    assert {:error, %Error{category: :store}} = Store.fetch(store, {"contract", "private"})
    assert {:error, %Error{category: :store}} = Store.accept(store, record, 10)

    assert %{rows: [[1]]} =
             Database.query(store, "SELECT count(*) FROM smolbox_executions WHERE partition=$1", [
               store.partition
             ])
  end

  test "projection corruption and transaction rollback cannot be mistaken for a new request", %{
    store: store
  } do
    record = Contract.record()
    assert {:ok, _, :inserted} = Store.accept(store, record, 10)

    assert {:error, :injected} =
             Repo.transact(fn ->
               Database.query(store, "DELETE FROM smolbox_executions WHERE partition=$1", [
                 store.partition
               ])

               {:error, :injected}
             end)

    assert {:ok, ^record} = Store.fetch(store, {"contract", "one"})

    Database.query(store, "UPDATE smolbox_executions SET version=99 WHERE partition=$1", [
      store.partition
    ])

    assert {:error, %Error{category: :store}} = Store.fetch(store, {"contract", "one"})
    assert {:error, %Error{category: :store}} = Store.accept(store, record, 10)
  end

  test "a managed durable runtime starts against the actual Repo and inspects accepted identity",
       %{store: store} do
    record = Contract.record()
    assert {:ok, _, :inserted} = Store.accept(store, record, 10)

    runtime =
      start_supervised!(
        {SmolBox,
         name: SmolBox.DurableExampleRuntime,
         namespace: "durable",
         store: {Store, store},
         artifact_store: {SmolBox.ArtifactStore.Directory, nil},
         fingerprint_key: :binary.copy(<<1>>, 32),
         workers: []}
      )

    assert {:ok, {"contract", "one"}} = SmolBox.submit(runtime, record.spec)
    assert {:ok, snapshot} = SmolBox.fetch(runtime, "contract", "one")
    assert snapshot.fingerprint == record.fingerprint
    assert snapshot.evidence == :not_dispatched
  end

  test "a fresh BEAM reads committed identity and due work from Postgres", %{store: store} do
    record = Contract.record()
    assert {:ok, _, :inserted} = Store.accept(store, record, 10)

    dir =
      Path.join(
        System.tmp_dir!(),
        "sbx-host-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    file = Path.join(dir, "key")
    File.write!(file, store.key)
    File.chmod!(file, 0o600)

    assert {"durable-read-ok\n", 0} =
             System.cmd(
               "mix",
               ["run", "--no-compile", "scripts/read_record.exs", store.partition, file],
               stderr_to_stdout: true
             )

    assert {:ok, ^record, :existing} = Store.accept(store, record, 10)
  end
end
