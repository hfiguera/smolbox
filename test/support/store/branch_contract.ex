defmodule SmolBox.Store.BranchContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{BranchPolicy, BranchSpec, ManagedMachine}
  alias SmolBox.Store.{Codec, Contract, MachineContract}

  def running(adapter, store),
    do: MachineContract.running_named(adapter, store, "source", [], nil, nil, true)

  def spec do
    {:ok, p} =
      BranchPolicy.new(id: "test", resources: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 8})

    {:ok, s} = BranchSpec.new(id: "child", policy: p, idle: true)
    s
  end

  def accept(
        adapter,
        store,
        m,
        spec \\ spec(),
        capacity \\ %{slots: 20, cpus: 64, memory_mb: 65_536, disk_gb: 1024}
      ) do
    fingerprint = BranchSpec.fingerprint(spec, ManagedMachine.key(m), :binary.copy(<<1>>, 32))

    adapter.machine(store, :branch_accept, [
      ManagedMachine.key(m),
      spec,
      fingerprint,
      "owned-child",
      capacity,
      1100
    ])
  end

  def advance(adapter, store, p, expected, change) do
    {:ok, p} = adapter.machine(store, :fetch, [ManagedMachine.key(p)])

    adapter.machine(store, :branch_advance, [
      ManagedMachine.key(p),
      Contract.guard(p),
      "child",
      expected,
      change,
      1200
    ])
  end

  def admission(adapter, store) do
    p = running(adapter, store)

    assert {:error, _} =
             accept(adapter, store, p, spec(), %{
               slots: 2,
               cpus: 64,
               memory_mb: 65_536,
               disk_gb: 1024
             })

    assert {:error, %{category: :not_found}} =
             adapter.machine(store, :fetch, [{p.scope, "child"}])

    assert {:ok, ^p} = adapter.machine(store, :fetch, [ManagedMachine.key(p)])
    assert {:ok, c} = accept(adapter, store, p)
    assert {:ok, ^c} = accept(adapter, store, p)

    assert {:error, %{category: :identity_conflict}} =
             accept(adapter, store, p, %{spec() | hold: true})

    assert {:ok, %{slots: 3, disk_gb: 12}} = adapter.usage(store, "worker")
    {:ok, active} = adapter.machine(store, :fetch, [ManagedMachine.key(p)])

    for action <- [:start, :stop, :delete],
        do:
          assert(
            {:error, _} =
              adapter.machine(store, :request, [
                ManagedMachine.key(p),
                action,
                active.version,
                1200
              ])
          )

    assert {:error, _} = accept(adapter, store, active, %{spec() | id: "other"})
  end

  def cancellation(adapter, store) do
    p = running(adapter, store)
    {:ok, c} = accept(adapter, store, p)

    assert {:ok, %{state: :deleted, branch: %{state: :cancelled}}} =
             advance(adapter, store, p, :accepted, :cancelled)

    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
    assert {:ok, %{branch: %{state: :cancelled}}} = accept(adapter, store, p)
    assert {:error, _} = advance(adapter, store, p, :accepted, :dispatching)
    assert {:ok, saved} = adapter.machine(store, :fetch, [ManagedMachine.key(c)])
    assert {:ok, <<"smolbox-record-v13\0", payload::binary>> = bytes} = Codec.encode(saved)
    assert {:ok, ^saved} = Codec.decode(bytes)

    for version <- 1..12,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))
  end

  def unknown(adapter, store) do
    p = running(adapter, store)
    {:ok, _} = accept(adapter, store, p)
    {:ok, _} = advance(adapter, store, p, :accepted, :dispatching)
    assert {:error, _} = advance(adapter, store, p, :dispatching, :failed)
    {:ok, c} = advance(adapter, store, p, :dispatching, :unknown)
    {:ok, p} = adapter.machine(store, :fetch, [ManagedMachine.key(p)])

    assert {:error, _} =
             adapter.machine(store, :resolve, [
               ManagedMachine.key(p),
               Contract.guard(p),
               :absent,
               1200
             ])

    assert {:error, _} =
             adapter.machine(store, :branch_retire, [
               ManagedMachine.key(p),
               Contract.guard(p),
               c.id,
               1200
             ])

    assert {:ok, c} =
             adapter.machine(store, :branch_resolve, [
               ManagedMachine.key(p),
               Contract.guard(p),
               c.id,
               p.created_machine,
               :absent,
               1200
             ])

    assert c.state == :deleted
    assert {:ok, %{slots: 2, disk_gb: 10}} = adapter.usage(store, "worker")
    {:ok, p} = adapter.machine(store, :fetch, [ManagedMachine.key(p)])

    assert {:ok, %{branch: %{state: :retired}}} =
             adapter.machine(store, :branch_retire, [
               ManagedMachine.key(p),
               Contract.guard(p),
               c.id,
               1200
             ])

    assert {:ok, %{slots: 2, disk_gb: 10}} = adapter.usage(store, "worker")
  end

  def competition(adapter, store) do
    p = running(adapter, store)

    results =
      ["one", "two"]
      |> Task.async_stream(fn id -> accept(adapter, store, p, %{spec() | id: id}) end)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, %{slots: 3}} = adapter.usage(store, "worker")
  end
end
