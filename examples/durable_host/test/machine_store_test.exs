defmodule SmolBox.DurableHost.MachineStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Store.{Contract, MachineContract}

  setup do
    partition = "machines-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for scenario <- [
        :acceptance,
        :shared_capacity,
        :command_admission,
        :lifecycle_race,
        :completion,
        :uncertainty,
        :takeover
      ] do
    test "PostgreSQL machine contract: #{scenario}", %{store: store} do
      apply(MachineContract, unquote(scenario), [Store, store])
    end
  end

  test "failed command insert rolls back the machine's active slot", %{store: store} do
    machine = MachineContract.running(Store, store)

    constraint =
      "reject_persistent_command_" <> Integer.to_string(System.unique_integer([:positive]))

    Database.query(
      store,
      "ALTER TABLE smolbox_executions ADD CONSTRAINT #{constraint} CHECK (execution_id <> 'rejected-managed-command')",
      []
    )

    on_exit(fn ->
      Database.query(store, "ALTER TABLE smolbox_executions DROP CONSTRAINT #{constraint}", [])
    end)

    command = Contract.record("rejected-managed-command")

    assert {:error, %{category: :store}} =
             Store.machine(store, :submit, [{machine.scope, machine.id}, command, 10, 1100])

    assert {:ok, %{active_execution: nil}} =
             Store.machine(store, :fetch, [{machine.scope, machine.id}])

    assert {:error, %{category: :not_found}} = Store.fetch(store, {command.scope, command.id})
    assert {:ok, %{slots: 1}} = Store.usage(store, "worker")
  end

  test "machine ciphertext cannot be substituted into an execution with the same identity", %{
    store: store
  } do
    record = MachineContract.record("one")
    assert {:ok, _} = Store.machine(store, :accept, [record, 10])
    command = Contract.record()
    assert {:ok, _, :inserted} = Store.accept(store, command, 10)

    Database.query(
      store,
      "UPDATE smolbox_executions e SET payload=m.payload FROM smolbox_managed_machines m WHERE e.partition=$1 AND m.partition=e.partition AND m.scope=e.scope AND m.execution_id=e.execution_id",
      [store.partition]
    )

    assert {:error, %{category: :store}} = Store.fetch(store, {"contract", "one"})
  end

  for scenario <- [:competition, :retention, :completion] do
    test "port ownership contract: #{scenario}", %{store: store} do
      apply(SmolBox.Store.PortContract, unquote(scenario), [Store, store])
    end
  end

  test "port ownership arbitrates across partitions and verifies its durable projection", %{
    store: store
  } do
    alias SmolBox.Store.PortContract
    {:ok, other} = Store.new(Repo, store.partition <> "-other", :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(other, "DELETE FROM smolbox_partitions WHERE partition=$1", [other.partition])
    end)

    claims =
      for context <- [store, other] do
        {:ok, _} = Store.claim_worker(context, "worker", "owner", 1000, 5000)
        {context, PortContract.claim(Store, context, "same-identity")}
      end

    results =
      claims
      |> Task.async_stream(fn {context, record} ->
        {context, PortContract.reserve(Store, context, record)}
      end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert [{winner, {:ok, record}}] = Enum.filter(results, &match?({_, {:ok, _}}, &1))

    assert [{loser, {:error, %{category: :port_conflict}}}] =
             Enum.reject(results, &match?({_, {:ok, _}}, &1))

    assert {:ok, %{slots: 0}} = Store.usage(loser, "worker")

    assert {:ok, %{reserved_ports: [], worker_id: nil}} =
             Store.machine(loser, :fetch, [{record.scope, record.id}])

    Database.query(winner, "DELETE FROM smolbox_port_owners WHERE partition=$1", [
      winner.partition
    ])

    assert {:error, %{category: :store}} =
             Store.machine(winner, :fetch, [{record.scope, record.id}])
  end
end
