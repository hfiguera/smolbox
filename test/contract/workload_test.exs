defmodule SmolBox.ManagedWorkloadTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Machines, ManagedPeer, Runtime, RuntimeFixture, Workload}
  alias SmolBox.Store.Memory

  defmodule OldStore do
    @moduledoc false
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks),
        operation != :capabilities do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def capabilities(store) do
      {:ok, capabilities} = Memory.capabilities(store)
      {:ok, Map.delete(capabilities, :managed_workloads)}
    end
  end

  defmodule UnavailableStore do
    @moduledoc false
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks), operation != :machine do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(operation)(unquote_splicing(arguments)),
        do: apply(Memory, unquote(operation), [unquote_splicing(arguments)])
    end

    def machine(_store, _operation, _arguments),
      do: {:error, %SmolBox.Error{category: :store, operation: :store}}
  end

  test "unavailable durable evidence blocks log access before worker observation" do
    fixture = RuntimeFixture.start()
    stop_supervised!(Runtime)

    options =
      fixture.options
      |> Keyword.put(:store, {UnavailableStore, fixture.store})
      |> Keyword.put(:workers, [])

    runtime = start_supervised!({Runtime, options})
    before = ManagedPeer.snapshot(fixture.peer).operations
    assert {:error, %{category: :store}} = Machines.logs(runtime, {"contract", "app"})
    assert ManagedPeer.snapshot(fixture.peer).operations == before
  end

  defp spec(fixture) do
    {:ok, workload} =
      Workload.new(
        entrypoint: ["python3"],
        cmd: ["app.py"],
        env: [{"APP", "private"}],
        workdir: "/app"
      )

    {:ok, spec} =
      SmolBox.ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "app",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile,
        workload: workload
      )

    spec
  end

  test "startup intent survives recovery; diagnostics coexist with commands and retain capacity" do
    fixture = RuntimeFixture.start()
    spec = spec(fixture)
    {:ok, handle} = Machines.create(fixture.runtime, spec)
    assert {:ok, created} = Machines.await(fixture.runtime, handle, 5000)
    assert created.state == :created
    assert {:ok, ^handle} = Machines.create(fixture.runtime, spec)

    assert {:error, %{category: :identity_conflict}} =
             Machines.create(fixture.runtime, %{spec | workload: nil})

    [wire] = ManagedPeer.snapshot(fixture.peer).creations
    assert wire["cmd"] == ["app.py"] and wire["workdir"] == "/app"
    assert wire["env"] == [%{"name" => "APP", "value" => "private"}]
    {:ok, _} = Machines.start(fixture.runtime, handle, created.version)
    {:ok, running} = Machines.await(fixture.runtime, handle, 5000)
    assert running.state == :running
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, fixture.options})
    {:ok, recovered} = Machines.inspect(runtime, handle)
    assert recovered.spec.workload == spec.workload
    assert recovered.machine_name == created.machine_name
    {:ok, execution} = Machines.submit(runtime, handle, fixture.spec)
    assert {:ok, %{lines: ["agent ready"]}} = Machines.logs(runtime, handle)
    assert {:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000)
    idle = RuntimeFixture.await_idle(runtime, handle)
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    {:ok, _} = Machines.stop(runtime, handle, idle.version)
    {:ok, stopped} = Machines.await(runtime, handle, 5000)
    {:ok, _} = Machines.start(runtime, handle, stopped.version)
    {:ok, restarted} = Machines.await(runtime, handle, 5000)
    assert restarted.spec.workload == spec.workload
    {:ok, _} = Machines.delete(runtime, handle, restarted.version)
    {:ok, deleted} = Machines.await(runtime, handle, 5000)
    assert deleted.state == :deleted and deleted.spec.workload == spec.workload
    assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
    assert {:error, _} = Machines.logs(runtime, handle)
  end

  test "log absence does not become machine absence; replaced incarnations are never read" do
    fixture = RuntimeFixture.start(no_logs: true)
    {:ok, handle} = Machines.create(fixture.runtime, spec(fixture))
    {:ok, created} = Machines.await(fixture.runtime, handle, 5000)
    assert {:error, %{category: :not_found}} = Machines.logs(fixture.runtime, handle)
    assert {:ok, ^created} = Machines.inspect(fixture.runtime, handle)

    Agent.update(fixture.peer, fn state ->
      put_in(state, [:machines, created.machine_name, "createdAt"], 1)
    end)

    before = ManagedPeer.snapshot(fixture.peer).operations
    assert {:error, %{category: :identity_conflict}} = Machines.logs(fixture.runtime, handle)
    after_ops = ManagedPeer.snapshot(fixture.peer).operations

    assert Enum.count(before, fn {_, p} -> String.ends_with?(p, "/logs") end) ==
             Enum.count(after_ops, fn {_, p} -> String.ends_with?(p, "/logs") end)

    assert {:ok, ^created} = Machines.inspect(fixture.runtime, handle)
  end

  test "old stores and workers reject workload admission without creation" do
    fixture = RuntimeFixture.start(expected_runtime_version: "1.16.1", runtime_version: "1.16.1")

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(fixture.runtime, spec(fixture))

    stop_supervised!(Runtime)

    runtime =
      start_supervised!(
        {Runtime, Keyword.put(fixture.options, :store, {OldStore, fixture.store})}
      )

    assert {:error, %{category: :unsupported_capability}} =
             Machines.create(runtime, spec(fixture))

    assert ManagedPeer.snapshot(fixture.peer).creations == []
  end
end
