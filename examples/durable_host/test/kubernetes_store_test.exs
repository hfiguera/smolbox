defmodule SmolBox.DurableHost.KubernetesStoreTest do
  use SmolBox.Store.KubernetesContract, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Kubernetes.{Assignment, Config}
  alias SmolBox.Store.KubernetesContract
  alias SmolBox.Test.Kubernetes, as: Fixture

  setup do
    partition = "kube-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{adapter: Store, store: store}
  end

  test "enrollment ciphertext and projections are authenticated", %{store: store} do
    {config, _, _} = KubernetesContract.reserved(Store, store)

    Database.query(
      store,
      "UPDATE smolbox_backend_bindings SET generation=$1 WHERE partition=$2 AND worker_id=$3",
      [String.duplicate("f", 64), store.partition, config.id]
    )

    assert {:error, %{category: :store}} =
             Store.bind_backend(store, config.id, Config.binding(config))
  end

  test "a lost ledger cannot alias an execution's domain", %{store: store} do
    {config, _, _} = KubernetesContract.reserved(Store, store)

    Database.query(store, "DELETE FROM smolbox_backend_bindings WHERE partition=$1", [
      store.partition
    ])

    {:ok, alias_config} = Fixture.config(id: "alias")

    assert {:error, %{category: :identity_conflict}} =
             Store.bind_backend(store, alias_config.id, Config.binding(alias_config))

    assert {:ok, %{slots: 1}} = Store.usage(store, config.id)
  end

  test "displaced worker projection fails complete recovery and enrollment scans", %{store: store} do
    {config, record, _} = KubernetesContract.reserved(Store, store)

    Database.query(
      store,
      "UPDATE smolbox_executions SET worker_id=NULL WHERE partition=$1 AND scope=$2 AND execution_id=$3",
      [store.partition, record.scope, record.id]
    )

    assert {:error, %{category: :store}} = Store.backend_assignments(store, config.id, nil, 1)

    assert {:error, %{category: :store}} =
             Store.bind_backend(store, config.id, Config.binding(config))
  end

  test "transaction rollback preserves absence of Kubernetes intent and charge", %{store: store} do
    {:ok, config} = Fixture.config()
    binding = Config.binding(config)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, ^binding} = Store.bind_backend(store, config.id, binding)
               {:error, :injected}
             end)

    assert %{rows: [[0]]} =
             Database.query(
               store,
               "SELECT count(*) FROM smolbox_backend_bindings WHERE partition=$1",
               [store.partition]
             )

    assert {:ok, _} = Store.bind_backend(store, config.id, binding)
    assert {:ok, _} = Store.claim_worker(store, config.id, "owner", 1000, 10_000)
    record = KubernetesContract.pending(Store, store, config)
    {:ok, assignment} = Assignment.new(config, record, "kube-rollback")

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        KubernetesContract.reserve(Store, store, config, record, assignment)

               {:error, :injected}
             end)

    assert {:ok, ^record} = Store.fetch(store, {record.scope, record.id})
    assert {:ok, %{slots: 0}} = Store.usage(store, config.id)
  end
end
