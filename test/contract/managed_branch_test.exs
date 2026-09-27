defmodule SmolBox.ManagedBranchTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    Branches,
    BranchPolicy,
    BranchSpec,
    Machines,
    ManagedMachineSpec,
    ManagedPeer,
    RuntimeFixture
  }

  alias SmolBox.Store.{MachineOps, Memory}

  defmodule LegacyStore do
    @moduledoc false
    alias SmolBox.Store.Memory

    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, :managed_branches)}
    end
  end

  test "missing branch capability rejects creation before acceptance" do
    {f, source, spec} = fixture()
    stop_supervised!(SmolBox.Runtime)

    runtime =
      start_supervised!({SmolBox.Runtime, Keyword.put(f.options, :store, {LegacyStore, f.store})})

    assert {:error, %{category: :unsupported_capability}} = Branches.create(runtime, source, spec)
    assert {:ok, %{branch_children: children}} = Machines.inspect(runtime, source)
    assert children == %{}
    assert count(f.peer, "/branches") == 0
  end

  test "draining the source worker rejects new branches" do
    {f, source, spec} = fixture()
    stop_supervised!(SmolBox.Runtime)
    workers = Enum.map(f.options[:workers], &%{&1 | draining: true})
    runtime = start_supervised!({SmolBox.Runtime, Keyword.put(f.options, :workers, workers)})
    assert {:error, %{category: :unsupported_capability}} = Branches.create(runtime, source, spec)
    assert count(f.peer, "/branches") == 0
  end

  test "children are durable managed machines with retained source dependencies" do
    {f, source, spec} = fixture()
    assert {:ok, child} = Branches.create(f.runtime, source, spec)

    assert {:ok, %{branch: %{state: :ready}, state: :running}} =
             Branches.await(f.runtime, child, 5000)

    assert {:ok, ^child} = Branches.create(f.runtime, source, spec)

    assert {:error, %{category: :identity_conflict}} =
             Branches.create(f.runtime, source, %{spec | hold: true})

    assert {:ok, %{slots: 3}} = Memory.usage(f.store, "peer")
    source_record = RuntimeFixture.await_idle(f.runtime, source)

    for action <- [:start, :stop, :delete],
        do:
          assert(
            {:error, _} = apply(Machines, action, [f.runtime, source, source_record.version])
          )

    assert {:error, _} = Branches.create(f.runtime, child, %{spec | id: "nested"})
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:ok, ^child} = Branches.create(runtime, source, spec)
    assert count(f.peer, "/branches") == 1
    delete(runtime, child)
    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")

    assert {:ok, %{branch: %{state: :retired}}} =
             Branches.retire(runtime, child, quiesced: true)

    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
    assert {:error, _} = Branches.release_storage(runtime, child, backing_removed: true)
    delete(runtime, source)
    assert {:ok, _} = Branches.release_storage(runtime, child, backing_removed: true)
    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(f.store, "peer")
    assert {:ok, ^child} = Branches.create(runtime, source, spec)
  end

  test "a held child cannot accept work until explicit release, which is deduplicated" do
    {f, source, spec} = fixture()
    {:ok, child} = Branches.create(f.runtime, source, %{spec | hold: true})
    assert {:ok, %{branch: %{state: :held}}} = Branches.await(f.runtime, child, 5000)
    current = RuntimeFixture.await_idle(f.runtime, child)
    assert {:error, _} = Machines.submit(f.runtime, child, %{f.spec | id: "held-command"})
    assert {:error, _} = Machines.stop(f.runtime, child, current.version)
    assert {:ok, _} = Branches.release(f.runtime, child, current.version)
    assert {:ok, %{branch: %{state: :released}}} = Branches.await(f.runtime, child, 5000)
    assert {:ok, _} = Branches.release(f.runtime, child, current.version)
    assert count(f.peer, "/branch-release") == 1

    assert {:ok, execution} =
             Machines.submit(f.runtime, child, %{f.spec | id: "released-command"})

    assert {:ok, %{state: :completed}} = SmolBox.await(f.runtime, execution, 5000)
  end

  test "a missing held child can resolve as deleted while retaining backing allowance" do
    {f, source, spec} = fixture()
    {:ok, child} = Branches.create(f.runtime, source, %{spec | hold: true})
    {:ok, %{branch: %{state: :held}} = current} = Branches.await(f.runtime, child, 5000)
    now = System.system_time(:millisecond)
    {:ok, missing} = SmolBox.ManagedMachine.update(current, %{state: :missing}, now)
    assert {:ok, deleted, nil} = MachineOps.resolve(missing, nil, :absent, now)
    assert deleted.state == :deleted
    assert deleted.branch.state == :held
    assert SmolBox.Branch.resources(deleted) == spec.policy.resources
  end

  test "lost creation response is never adopted by name or replayed" do
    {f, source, spec} = fixture(branch_lost: true)
    {:ok, child} = Branches.create(f.runtime, source, spec)

    assert {:ok, %{branch: %{state: :unknown}, created_machine: nil} = c} =
             Branches.await(f.runtime, child, 5000)

    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, f.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:error, _} = Branches.resolve(runtime, child, quiesced: true, disposition: :keep)
    assert {:error, _} = Branches.retire(runtime, child, quiesced: true)
    assert {:error, _} = Branches.create(runtime, source, %{spec | id: "second"})
    assert count(f.peer, "/branches") == 1
    Agent.update(f.peer, &%{&1 | machines: Map.delete(&1.machines, c.machine_name)})

    assert {:ok, %{state: :deleted, branch: %{state: :resolved}}} =
             Branches.resolve(runtime, child, quiesced: true, disposition: :deleted)

    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
    assert {:ok, _} = Branches.retire(runtime, child, quiesced: true)
    assert {:ok, %{slots: 2}} = Memory.usage(f.store, "peer")
  end

  test "lost release response cannot be inferred from a cleared held flag" do
    {f, source, spec} = fixture(release_lost: true)
    {:ok, child} = Branches.create(f.runtime, source, %{spec | hold: true})
    {:ok, _} = Branches.await(f.runtime, child, 5000)
    current = RuntimeFixture.await_idle(f.runtime, child)
    {:ok, _} = Branches.release(f.runtime, child, current.version)
    assert {:ok, %{branch: %{state: :unknown}}} = Branches.await(f.runtime, child, 5000)
    assert {:error, _} = Branches.resolve(f.runtime, child, quiesced: true, disposition: :keep)
    assert {:ok, _} = Branches.release(f.runtime, child, current.version)
    assert count(f.peer, "/branch-release") == 1
  end

  test "owned source mismatch rejects before dispatch and releases extra admission" do
    {f, source, spec} = fixture()

    Agent.update(f.peer, fn state ->
      %{
        state
        | machines: Map.new(state.machines, fn {n, m} -> {n, Map.put(m, "createdAt", 4)} end)
      }
    end)

    {:ok, child} = Branches.create(f.runtime, source, spec)
    assert {:ok, %{branch: %{state: :failed}}} = Branches.await(f.runtime, child, 5000)
    assert count(f.peer, "/branches") == 0
    assert {:ok, %{slots: 1}} = Memory.usage(f.store, "peer")
  end

  for {event, phase, expected, requests} <- [
        {:branch_intent, :before, :ready, 1},
        {:branch_intent, :after, :unknown, 0},
        {:branch_receipt, :before, :unknown, 1},
        {:branch_receipt, :after, :ready, 1}
      ] do
    test "store failure #{event}/#{phase} retains branch evidence" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!({Agent, fn -> %{failure: {event, phase}, observer: observer} end},
          id: :failure
        )

      {f, source, spec} = fixture(faults: gate)
      {:ok, child} = Branches.create(f.runtime, source, spec)
      assert_receive {:store_failure, ^event, ^phase}, 5000

      assert {:ok, %{branch: %{state: unquote(expected)}}} =
               Branches.await(f.runtime, child, 5000)

      assert count(f.peer, "/branches") == unquote(requests)
      assert {:ok, %{slots: 3}} = Memory.usage(f.store, "peer")
    end

    test "restart #{event}/#{phase} never replays a dispatched branch" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: event, phase: phase, observer: observer, fired: false} end},
          id: :gate
        )

      {f, source, spec} = fixture(faults: gate)
      {:ok, child} = Branches.create(f.runtime, source, spec)
      assert_receive {:boundary, ^event, ^phase, _}, 5000
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, f.options})
      RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
      assert {:ok, %{branch: %{state: unquote(expected)}}} = Branches.await(runtime, child, 5000)
      assert count(f.peer, "/branches") == unquote(requests)
    end
  end

  test "competing controllers, cancellation and late responses retain the lock" do
    observer = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: :branch, phase: :after, observer: observer, fired: false} end},
        id: :gate
      )

    {f, source, spec} = fixture(faults: gate)

    other =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(f.options, :name, SmolBox.OtherBranchRuntime)},
        id: :other
      )

    results =
      [{f.runtime, spec}, {other, %{spec | id: "other"}}]
      |> Task.async_stream(fn {runtime, request} -> Branches.create(runtime, source, request) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, child}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert_receive {:boundary, :branch, :after, blocked}, 5000
    assert {:ok, %{branch: %{state: :unknown}}} = Branches.cancel(f.runtime, child)
    assert {:error, _} = Machines.submit(f.runtime, source, f.spec)
    send(blocked, :release_boundary)
    assert {:ok, %{branch: %{state: :unknown}}} = Branches.await(f.runtime, child, 5000)
    assert {:ok, %{slots: 3}} = Memory.usage(f.store, "peer")
    assert count(f.peer, "/branches") == 1
  end

  test "source and child absence permit explicit recovery" do
    {f, source, spec} = fixture(branch_lost: true)
    {:ok, child} = Branches.create(f.runtime, source, spec)
    {:ok, _} = Branches.await(f.runtime, child, 5000)
    Agent.update(f.peer, &%{&1 | machines: %{}})

    assert {:ok, %{state: :deleted}} =
             Branches.resolve(f.runtime, child, quiesced: true, disposition: :deleted)

    assert {:ok, %{state: :missing}} = Machines.inspect(f.runtime, source)
    assert {:ok, _} = Branches.retire(f.runtime, child, quiesced: true)
    {:ok, p} = Machines.inspect(f.runtime, source)

    assert {:ok, %{state: :deleted}} =
             Machines.resolve(f.runtime, source, p.version, quiesced: true, disposition: :deleted)

    assert {:ok, _} = Branches.release_storage(f.runtime, child, backing_removed: true)
    assert {:ok, %{slots: 0}} = Memory.usage(f.store, "peer")
  end

  for {event, phase, expected, requests} <- [
        {:release_intent, :before, :released, 1},
        {:release_intent, :after, :unknown, 0},
        {:release_result, :before, :unknown, 1},
        {:release_result, :after, :released, 1}
      ] do
    test "restart #{event}/#{phase} preserves one-time release evidence" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: event, phase: phase, observer: observer, fired: false} end},
          id: :release_gate
        )

      {f, source, spec} = fixture(faults: gate)
      {:ok, child} = Branches.create(f.runtime, source, %{spec | hold: true})
      {:ok, _} = Branches.await(f.runtime, child, 5000)
      current = RuntimeFixture.await_idle(f.runtime, child)
      {:ok, _} = Branches.release(f.runtime, child, current.version)
      assert_receive {:boundary, ^event, ^phase, _}, 5000
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, f.options})
      RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
      assert {:ok, %{branch: %{state: unquote(expected)}}} = Branches.await(runtime, child, 5000)
      assert {:ok, _} = Branches.release(runtime, child, current.version)
      assert count(f.peer, "/branch-release") == unquote(requests)
      assert {:ok, %{slots: 3}} = Memory.usage(f.store, "peer")
    end
  end

  test "unavailable observations cannot resolve a lost branch as absent" do
    {f, source, spec} = fixture(branch_lost: true)
    {:ok, child} = Branches.create(f.runtime, source, spec)
    {:ok, _} = Branches.await(f.runtime, child, 5000)
    Agent.update(f.peer, &%{&1 | options: Keyword.put(&1.options, :inspect_unavailable, true)})
    assert {:error, _} = Branches.resolve(f.runtime, child, quiesced: true, disposition: :deleted)
    assert {:ok, %{branch: %{state: :unknown}}} = Branches.fetch(f.runtime, child)
    assert {:ok, %{slots: 3}} = Memory.usage(f.store, "peer")
  end

  defp delete(runtime, handle) do
    current = RuntimeFixture.await_idle(runtime, handle)
    assert {:ok, _} = Machines.delete(runtime, handle, current.version)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, handle, 5000)
  end

  defp fixture(options \\ []) do
    {:ok, policy} =
      BranchPolicy.new(
        id: "branches",
        resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 8}
      )

    f =
      RuntimeFixture.start(
        __MODULE__,
        options ++
          [
            capture: true,
            branch_policies: [policy],
            capacity: %{slots: 8, cpus: 16, memory_mb: 16_384, disk_gb: 128}
          ]
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: f.spec.scope,
        id: "source",
        artifact: f.spec.artifact,
        profile: f.spec.profile,
        checkpointable: true
      )

    {:ok, source} = Machines.create(f.runtime, spec)
    {:ok, _} = Machines.await(f.runtime, source, 5000)
    current = RuntimeFixture.await_idle(f.runtime, source)
    {:ok, _} = Machines.start(f.runtime, source, current.version)
    {:ok, %{state: :running}} = Machines.await(f.runtime, source, 5000)
    RuntimeFixture.await_idle(f.runtime, source)
    {:ok, spec} = BranchSpec.new(id: "child", policy: policy, idle: true)
    {f, source, spec}
  end

  defp count(peer, suffix),
    do:
      Enum.count(ManagedPeer.snapshot(peer).operations, fn {method, path} ->
        method == "POST" and String.ends_with?(path, suffix)
      end)
end
