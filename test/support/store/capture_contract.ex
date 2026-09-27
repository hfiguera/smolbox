defmodule SmolBox.Store.CaptureContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.{
    CheckpointCapture,
    CheckpointCaptureSpec,
    CheckpointPolicy,
    CheckpointResult,
    ManagedMachine
  }

  alias SmolBox.Store.{Contract, MachineContract}

  def running(adapter, store),
    do: MachineContract.running_named(adapter, store, "capture", [], nil, nil, true)

  def spec do
    {:ok, p} =
      CheckpointPolicy.new(
        id: "capture",
        root: "/private/checkpoints",
        max_bytes: 1_073_741_824,
        resources: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 16}
      )

    {:ok, s} = CheckpointCaptureSpec.new(id: "one", policy: p, idle: true)
    s
  end

  def accept(adapter, store, m, spec \\ spec()) do
    fingerprint =
      CheckpointCaptureSpec.fingerprint(spec, ManagedMachine.key(m), :binary.copy(<<1>>, 32))

    adapter.machine(store, :capture_accept, [
      ManagedMachine.key(m),
      spec,
      fingerprint,
      %{slots: 20, cpus: 64, memory_mb: 65_536, disk_gb: 1024},
      1100
    ])
  end

  def advance(adapter, store, m, state, changes),
    do:
      adapter.machine(store, :capture_advance, [
        ManagedMachine.key(m),
        Contract.guard(m),
        "one",
        state,
        changes,
        1200
      ])

  def admission(adapter, store) do
    m = running(adapter, store)
    assert {:ok, active} = accept(adapter, store, m)
    assert {:ok, ^active} = accept(adapter, store, active)

    assert {:error, %{category: :identity_conflict}} =
             accept(adapter, store, active, %{spec() | timeout_ms: 1000})

    for action <- [:start, :stop, :delete],
        do:
          assert(
            {:error, _} =
              adapter.machine(store, :request, [
                ManagedMachine.key(active),
                action,
                active.version,
                1100
              ])
          )

    assert {:error, _} = accept(adapter, store, active, %{spec() | id: "other"})
    assert {:ok, %{slots: 2, disk_gb: 18}} = adapter.usage(store, "worker")
  end

  def cancellation(adapter, store) do
    m = running(adapter, store)
    {:ok, m} = accept(adapter, store, m)

    assert {:ok, cancelled} =
             adapter.machine(store, :capture_cancel, [ManagedMachine.key(m), "one", 1200])

    assert cancelled.captures["one"].state == :cancelled
    assert ManagedMachine.idle?(cancelled)
    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
  end

  def unknown(adapter, store) do
    m = running(adapter, store)
    {:ok, m} = accept(adapter, store, m)
    {:ok, m} = advance(adapter, store, m, :accepted, state: :dispatching)
    assert {:error, _} = advance(adapter, store, m, :dispatching, state: :failed)
    {:ok, m} = adapter.machine(store, :capture_cancel, [ManagedMachine.key(m), "one", 1200])
    assert m.captures["one"].state == :unknown

    assert {:error, _} =
             adapter.machine(store, :resolve, [
               ManagedMachine.key(m),
               Contract.guard(m),
               m.observed_machine,
               1200
             ])

    assert {:error, _} =
             adapter.machine(store, :capture_resolve, [
               ManagedMachine.key(m),
               Contract.guard(m),
               "one",
               %{m.observed_machine | created_at: 9},
               1200
             ])

    assert {:ok, m} =
             adapter.machine(store, :capture_resolve, [
               ManagedMachine.key(m),
               Contract.guard(m),
               "one",
               m.observed_machine,
               1200
             ])

    assert m.captures["one"].state == :resolved_unknown
    assert {:ok, %{slots: 1, disk_gb: 3}} = adapter.usage(store, "worker")

    assert {:ok, m} =
             adapter.machine(store, :capture_release, [
               ManagedMachine.key(m),
               Contract.guard(m),
               "one",
               1200
             ])

    assert {:ok, %{slots: 1, disk_gb: 2}} = adapter.usage(store, "worker")
    assert {:ok, ^m} = accept(adapter, store, m)
  end

  def retention(adapter, store) do
    m = running(adapter, store)
    {:ok, m} = accept(adapter, store, m)
    {:ok, m} = advance(adapter, store, m, :accepted, state: :dispatching)

    r = %CheckpointResult{
      path: CheckpointCapture.path(m.captures["one"]),
      sha256: String.duplicate("a", 64),
      size_bytes: 100,
      profile: m.spec.profile,
      platform: :linux,
      architecture: "x86_64",
      runtime_version: "1.19.0"
    }

    {:ok, m} = advance(adapter, store, m, :dispatching, state: :captured, result: r)
    assert {:ok, %{slots: 2}} = adapter.usage(store, "worker")

    {:ok, m} =
      adapter.machine(store, :capture_resolve, [
        ManagedMachine.key(m),
        Contract.guard(m),
        "one",
        m.observed_machine,
        1200
      ])

    assert {:ok, %{slots: 1, disk_gb: 3}} = adapter.usage(store, "worker")

    {:ok, m} =
      adapter.machine(store, :write, [
        ManagedMachine.key(m),
        Contract.guard(m),
        [state: :deleted, absence_at_ms: 1300],
        1300
      ])

    assert {:ok, %{slots: 0, disk_gb: 1}} = adapter.usage(store, "worker")
    assert m.captures["one"].result == r

    assert {:ok, _} =
             adapter.machine(store, :capture_release, [
               ManagedMachine.key(m),
               Contract.guard(m),
               "one",
               1300
             ])

    assert {:ok, %{slots: 0, disk_gb: 0}} = adapter.usage(store, "worker")
  end

  def competition(adapter, store) do
    m = running(adapter, store)

    results =
      [spec(), %{spec() | id: "other"}]
      |> Task.async_stream(&accept(adapter, store, m, &1))
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:ok, %{slots: 2}} = adapter.usage(store, "worker")
  end
end
