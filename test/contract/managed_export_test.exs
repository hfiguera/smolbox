defmodule SmolBox.ManagedExportTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    ExportPeer,
    ExportResult,
    Exports,
    ExportSpec,
    Machines,
    ManagedMachineSpec,
    ManagedPeer,
    RuntimeFixture
  }

  alias SmolBox.Store.{Codec, Memory}

  defmodule Credentials do
    @behaviour SmolBox.RegistryCredentials
    @impl true
    def fetch(agent, "publisher") do
      Agent.get(agent, fn state ->
        if Map.get(state, :credential_failure),
          do: {:error, state.token},
          else: {:ok, state.token}
      end)
    end
  end

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
      {:ok, Map.delete(capabilities, :managed_exports)}
    end
  end

  test "a store without export capability is rejected before durable acceptance" do
    {fixture, registry, machine, spec} = fixture()
    stop_supervised!(SmolBox.Runtime)

    runtime =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(fixture.options, :store, {LegacyStore, fixture.store})}
      )

    assert {:error, %{category: :unsupported_capability}} = Exports.submit(runtime, machine, spec)
    assert {:ok, %{exports: exports}} = Machines.inspect(runtime, machine)
    assert exports == %{}
    assert Agent.get(registry, & &1.publications) == 0
  end

  test "controllers sharing a store admit only one conflicting export" do
    {fixture, registry, machine, spec} = fixture()

    other =
      start_supervised!(
        {SmolBox.Runtime, Keyword.put(fixture.options, :name, SmolBox.OtherExportRuntime)},
        id: :other_export_runtime
      )

    results =
      [{fixture.runtime, spec}, {other, %{spec | id: "second", tag: "second"}}]
      |> Task.async_stream(fn {runtime, request} -> Exports.submit(runtime, machine, request) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, handle}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:ok, %{state: :published}} = Exports.await(fixture.runtime, handle, 5000)
    assert Agent.get(registry, & &1.publications) == 1
    assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
  end

  for event <- [:exec, :upload, :download, :terminal_open] do
    test "active #{event} excludes export and stop" do
      observer = self()
      event = unquote(event)

      gate =
        start_supervised!(
          {Agent, fn -> %{event: event, phase: :before, observer: observer, fired: false} end},
          id: :work_gate
        )

      {fixture, registry, machine, spec} = fixture(faults: gate)
      stopped = RuntimeFixture.await_idle(fixture.runtime, machine)
      {:ok, _} = Machines.start(fixture.runtime, machine, stopped.version)
      {:ok, %{state: :running}} = Machines.await(fixture.runtime, machine, 5000)
      request = work_spec(fixture.spec, event)
      {:ok, execution} = Machines.submit(fixture.runtime, machine, request)
      assert_receive {:boundary, ^event, :before, blocked}, 5000
      assert {:ok, busy} = Machines.inspect(fixture.runtime, machine)
      assert busy.active_execution == execution
      assert {:error, _} = Exports.submit(fixture.runtime, machine, spec)
      assert {:error, _} = Machines.stop(fixture.runtime, machine, busy.version)
      assert Agent.get(registry, & &1.publications) == 0
      assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
      send(blocked, :release_boundary)

      finish_work(event, fixture.runtime, execution)
    end
  end

  test "ownership mismatch prevents dispatch and preserves the source reservation" do
    {fixture, registry, machine, spec} = fixture()

    Agent.update(fixture.peer, fn state ->
      machines =
        Map.new(state.machines, fn {name, observed} ->
          {name, Map.put(observed, "createdAt", 999)}
        end)

      %{state | machines: machines}
    end)

    assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)
    assert {:ok, %{state: :failed}} = Exports.await(fixture.runtime, handle, 5000)
    assert count(fixture.peer, "/export") == 0
    assert Agent.get(registry, & &1.publications) == 0
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
  end

  test "credential resolution failure stays before dispatch and redacts the resolver detail" do
    {fixture, registry, machine, spec} = fixture()
    Agent.update(registry, &Map.put(&1, :credential_failure, true))
    assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)

    assert {:ok, %{state: :failed, error: %{category: :authentication}}} =
             Exports.await(fixture.runtime, handle, 5000)

    assert {:ok, record} = Machines.inspect(fixture.runtime, machine)
    assert {:ok, bytes} = Codec.encode(record)
    refute bytes =~ "export-test-token"
    assert count(fixture.peer, "/export") == 0
    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
  end

  for action <- [:cancel, :deadline] do
    test "#{action} after dispatch retains uncertainty even when the worker later publishes" do
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: :export, phase: :before, observer: observer, fired: false} end},
          id: :export_gate
        )

      {fixture, registry, machine, original} = fixture(faults: gate)
      spec = %{original | timeout_ms: 1000}
      # The submitting process exits; the runtime owns durable work independently.
      assert {:ok, handle} =
               Task.async(fn -> Exports.submit(fixture.runtime, machine, spec) end)
               |> Task.await()

      assert_receive {:boundary, :export, :before, blocked}, 5000

      if unquote(action) == :cancel,
        do: assert({:ok, %{state: :unknown}} = Exports.cancel(fixture.runtime, handle))

      assert {:ok, %{state: :unknown}} = Exports.await(fixture.runtime, handle, 3000)
      assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
      send(blocked, :release_boundary)
      wait_publication(registry, System.monotonic_time(:millisecond) + 3000)
      assert {:ok, %{state: :unknown, result: nil}} = Exports.fetch(fixture.runtime, handle)
      assert count(fixture.peer, "/export") == 1
    end
  end

  for {event, phase, expected, publications} <- [
        {:export_intent, :before, :published, 1},
        {:export_intent, :after, :unknown, 0},
        {:export_receipt, :before, :unknown, 1},
        {:export_receipt, :after, :published, 1},
        {:export_result, :before, :published, 1},
        {:export_result, :after, :published, 1}
      ] do
    test "store failure at #{event}/#{phase} preserves committed intent and never replays" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!({Agent, fn -> %{failure: {event, phase}, observer: observer} end},
          id: :write_failure
        )

      {fixture, registry, machine, spec} = fixture(faults: gate)
      assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)
      assert_receive {:store_failure, ^event, ^phase}, 5000
      assert {:ok, %{state: unquote(expected)}} = Exports.await(fixture.runtime, handle, 5000)
      assert Agent.get(registry, & &1.publications) == unquote(publications)
      assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
    end

    test "restart at #{event}/#{phase} never replays export dispatch" do
      event = unquote(event)
      phase = unquote(phase)
      observer = self()

      gate =
        start_supervised!(
          {Agent, fn -> %{event: event, phase: phase, observer: observer, fired: false} end},
          id: :export_gate
        )

      {fixture, registry, machine, spec} = fixture(faults: gate)
      assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)
      assert_receive {:boundary, ^event, ^phase, _blocked}, 5000
      stop_supervised!(SmolBox.Runtime)
      runtime = start_supervised!({SmolBox.Runtime, fixture.options})
      RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
      assert {:ok, %{state: unquote(expected)}} = Exports.await(runtime, handle, 5000)
      assert Agent.get(registry, & &1.publications) == unquote(publications)
      assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
    end
  end

  test "verified export persists distinct identities and leaves the source stopped across restart" do
    {fixture, registry, machine, spec} = fixture()
    assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)

    assert {:ok, %{state: :published, result: result}} =
             Exports.await(fixture.runtime, handle, 5000)

    assert {:ok, source} = ExportResult.source(result, id: "exported", credential_ref: "reader")
    assert source.sha256 == result.manifest_sha256
    refute source.sha256 == source.content_sha256
    assert {:ok, record} = Machines.inspect(fixture.runtime, machine)
    assert record.state == :stopped and record.active_export == spec.id
    assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
    # This simulated peer has no helper. Production operators must establish
    # this separately; an export response alone never releases its capacity.
    assert {:ok, %{state: :completed}} =
             Exports.resolve(fixture.runtime, handle, record.version, quiesced: true)

    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    assert {:ok, bytes} = Codec.encode(record)
    refute bytes =~ "export-test-token"
    refute bytes =~ "PRIVATE=not-for-records"
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:ok, ^handle} = Exports.submit(runtime, machine, spec)
    assert {:ok, %{result: ^result}} = Exports.fetch(runtime, handle)
    assert Agent.get(registry, & &1.publications) == 1
    idle = RuntimeFixture.await_idle(runtime, machine)
    assert {:ok, _} = Machines.delete(runtime, machine, idle.version)
    assert {:ok, %{state: :deleted}} = Machines.await(runtime, machine, 5000)
    assert {:ok, %{state: :completed}} = Exports.fetch(runtime, handle)
    assert {:ok, ^handle} = Exports.submit(runtime, machine, spec)
    assert {:ok, %{slots: 0}} = Memory.usage(fixture.store, "peer")
    assert map_size(Agent.get(registry, & &1.objects)) == 5
  end

  test "lost export response blocks reuse without replay, even if publication succeeded" do
    {fixture, registry, machine, spec} = fixture(export_lost: true)
    assert {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)
    assert {:ok, %{state: :unknown, receipt: nil}} = Exports.await(fixture.runtime, handle, 5000)
    assert Agent.get(registry, & &1.publications) == 1
    stop_supervised!(SmolBox.Runtime)
    runtime = start_supervised!({SmolBox.Runtime, fixture.options})
    RuntimeFixture.wait_ready(runtime, System.monotonic_time(:millisecond) + 10_000)
    assert {:ok, ^handle} = Exports.submit(runtime, machine, spec)
    assert {:ok, blocked} = Machines.inspect(runtime, machine)

    for operation <- [:start, :stop, :delete],
        do: assert({:error, _} = apply(Machines, operation, [runtime, machine, blocked.version]))

    assert {:error, _} = Machines.resolve(runtime, machine, blocked.version, quiesced: true)
    assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
    assert Agent.get(registry, & &1.publications) == 1
    assert {:ok, current} = Machines.inspect(runtime, machine)

    assert {:ok, %{state: :resolved_unknown, result: nil}} =
             Exports.resolve(runtime, handle, current.version, quiesced: true)

    assert {:ok, %{slots: 1}} = Memory.usage(fixture.store, "peer")
    assert count(fixture.peer, "/export") == 1
  end

  test "deleted disposition requires verified absence and retains export deduplication" do
    {fixture, registry, machine, spec} = fixture(export_lost: true)
    {:ok, handle} = Exports.submit(fixture.runtime, machine, spec)
    {:ok, %{state: :unknown}} = Exports.await(fixture.runtime, handle, 5000)
    {:ok, current} = Machines.inspect(fixture.runtime, machine)

    assert {:error, _} =
             Exports.resolve(fixture.runtime, handle, current.version,
               quiesced: true,
               disposition: :deleted
             )

    assert {:ok, %{slots: 2}} = Memory.usage(fixture.store, "peer")
    # Simulate explicit operator cleanup after fencing the completed peer request.
    Agent.update(fixture.peer, &%{&1 | machines: Map.delete(&1.machines, current.machine_name)})
    {:ok, latest} = Machines.inspect(fixture.runtime, machine)

    assert {:ok, %{state: :resolved_unknown}} =
             Exports.resolve(fixture.runtime, handle, latest.version,
               quiesced: true,
               disposition: :deleted
             )

    assert {:ok, %{state: :deleted, reservation: nil}} =
             Machines.inspect(fixture.runtime, machine)

    assert {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(fixture.store, "peer")
    assert {:ok, ^handle} = Exports.submit(fixture.runtime, machine, spec)
    assert Agent.get(registry, & &1.publications) == 1
  end

  defp fixture(options \\ []) do
    {registry, destination} = ExportPeer.start()

    fixture =
      RuntimeFixture.start(
        __MODULE__,
        options ++
          [
            export_destinations: [destination],
            registry_credentials: {Credentials, registry},
            export_response: &ExportPeer.publish(registry, &1),
            capacity: %{slots: 4, cpus: 16, memory_mb: 16_384, disk_gb: 1024}
          ]
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: fixture.spec.scope,
        id: "export-machine",
        artifact: fixture.spec.artifact,
        profile: fixture.spec.profile
      )

    {:ok, machine} = Machines.create(fixture.runtime, spec)
    {:ok, _} = Machines.await(fixture.runtime, machine, 5000)
    idle = RuntimeFixture.await_idle(fixture.runtime, machine)
    {:ok, _} = Machines.stop(fixture.runtime, machine, idle.version)
    {:ok, %{state: :stopped}} = Machines.await(fixture.runtime, machine, 5000)
    {:ok, export} = ExportSpec.new(id: "save-one", tag: "save-one", destination: destination)
    {fixture, registry, machine, export}
  end

  defp count(peer, suffix),
    do:
      Enum.count(ManagedPeer.snapshot(peer).operations, fn {method, path} ->
        method == "POST" and String.ends_with?(path, suffix)
      end)

  defp wait_publication(registry, deadline) do
    if Agent.get(registry, & &1.publications) == 0 do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      wait_publication(registry, deadline)
    end
  end

  defp work_spec(spec, :terminal_open), do: %{spec | command: %SmolBox.Terminal.Spec{}}
  defp work_spec(spec, :exec), do: spec

  defp work_spec(spec, _file_phase) do
    input = %{
      "source" => "input",
      "path" => "/workspace/export-input",
      "size" => 2,
      "sha256" => SmolBox.Files.sha256(<<0, 255>>),
      "mode" => "runtime_default"
    }

    output = %{
      "destination" => "export-output",
      "path" => "/workspace/export-input",
      "max_bytes" => 2
    }

    %{spec | inputs: [input], outputs: [output]}
  end

  defp finish_work(:terminal_open, runtime, execution) do
    {:ok, terminal} = SmolBox.Terminal.attach(runtime, execution)
    SmolBox.Terminal.close(terminal)
  end

  defp finish_work(_event, runtime, execution),
    do: assert({:ok, %{state: :completed}} = SmolBox.await(runtime, execution, 5000))
end
