defmodule SmolBox.TelemetryTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Command, Error, Files, ManagedPeer, Runtime, RuntimeFixture, Telemetry}
  alias SmolBox.Store.Contract
  alias SmolBox.Telemetry.Dispatcher

  test "managed events describe persisted stages and measurements without execution payloads" do
    attach(:forward)
    context = RuntimeFixture.start()

    {:ok, command} =
      Command.new(["true", "uploaded-code-secret"], env: [{"SECRET", "credential-secret"}])

    Agent.update(context.artifacts, &Map.put(&1, {"contract", "input"}, "file-content-secret"))

    spec = %{
      context.spec
      | command: command,
        metadata: %{"private" => "business-input-secret"},
        inputs: [
          %{
            "source" => "input",
            "path" => "/workspace/private-source",
            "size" => 19,
            "sha256" => Files.sha256("file-content-secret"),
            "mode" => "runtime_default"
          }
        ],
        outputs: [
          %{"destination" => "private-result", "path" => "/workspace/out.bin", "max_bytes" => 32}
        ]
    }

    assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, result} = SmolBox.await(context.runtime, handle, 5000)
    assert result.result.exit_code == 7
    events = collect_cleanup()
    assert Enum.any?(events, fn {name, _, _} -> name == [:smolbox, :execution, :accepted] end)

    assert Enum.any?(events, fn {name, measurements, _} ->
             name == [:smolbox, :execution, :reserved] and measurements.queue_wait_ms >= 0
           end)

    for stage <- [:preparation, :execution, :collection, :cleanup] do
      assert Enum.any?(events, fn {name, measurements, metadata} ->
               name == [:smolbox, :stage, :stop] and metadata.stage == stage and
                 measurements.duration_ms >= 0
             end)
    end

    assert Enum.any?(events, fn {_name, measurements, metadata} ->
             metadata[:evidence] == :exited and measurements[:exit_code] == 7 and
               measurements[:stdout_bytes] == 7
           end)

    {:ok, clean} = SmolBox.fetch(context.runtime, spec.scope, spec.id)
    assert clean.cleanup == :complete and clean.reservation == nil
    blob = :erlang.term_to_binary(events)

    for secret <- [
          "uploaded-code-secret",
          "credential-secret",
          "file-content-secret",
          "business-input-secret",
          "private-source",
          "private-result",
          "started",
          clean.fingerprint
        ] do
      assert :binary.match(blob, secret) == :nomatch
    end

    assert Enum.all?(events, &(:erlang.external_size(&1) <= 4096))
    assert :ok = SmolBox.drain_worker(context.runtime, "peer")
    assert_receive {:event, [:smolbox, :worker, :status], %{count: 1}, %{status: :draining}}, 1000
    assert {:ok, %{available: true}} = SmolBox.telemetry_stats(context.runtime)
  end

  test "blocking exporters cannot hold up execution, result persistence or cleanup" do
    attach(:block)
    context = RuntimeFixture.start(telemetry_max_pending: 2, telemetry_timeout_ms: 1000)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert_receive {:event, _name, _measurements, _metadata}, 1000
    clean = clean_record(context.runtime, handle)
    assert clean.state == :completed and clean.result.exit_code == 7
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
    assert {:ok, %{dropped: dropped, limit: 2}} = SmolBox.telemetry_stats(context.runtime)
    assert dropped > 0
  end

  test "cancellation and unknown execution remain distinct observable evidence" do
    attach(:forward)
    observer = self()

    gate =
      start_supervised!(
        {Agent,
         fn ->
           %{event: :first_output_record, phase: :after, observer: observer, fired: false}
         end},
        id: :cancellation_gate
      )

    context = RuntimeFixture.start(faults: gate, hold: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert_receive {:boundary, :first_output_record, :after, blocked}, 5000
    assert {:ok, ^handle} = SmolBox.cancel(context.runtime, context.spec.scope, context.spec.id)
    assert_receive {:event, [:smolbox, :execution, :cancel_requested], _, _}, 1000
    send(blocked, :release_boundary)

    assert_receive {:event, [:smolbox, :execution, :updated], measurements,
                    %{state: :unknown, evidence: :unknown}},
                   1000

    assert measurements.reserved_slots == 1
    refute Map.has_key?(measurements, :exit_code)
    assert {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
    assert record.result == nil and record.cancel_requested_at_ms != nil
    assert measurements.cancel_requested_at_ms == record.cancel_requested_at_ms
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
  end

  for phase <- [:before, :after] do
    test "notification process death #{phase} result persistence preserves the command and work subtree" do
      observer = self()

      gate =
        start_supervised!(
          {Agent,
           fn ->
             %{event: :result_write, phase: unquote(phase), observer: observer, fired: false}
           end},
          id: :notification_gate
        )

      context = RuntimeFixture.start(faults: gate)
      assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
      phase = unquote(phase)
      assert_receive {:boundary, :result_write, ^phase, blocked}, 5000
      coordinator = Runtime.coordinator(context.runtime)
      {:ok, before} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)

      {Dispatcher, dispatcher, :worker, _} =
        Enum.find(Supervisor.which_children(context.runtime), &(elem(&1, 0) == Dispatcher))

      Process.exit(dispatcher, :kill)
      assert Process.alive?(blocked)
      assert Runtime.coordinator(context.runtime) == coordinator
      send(blocked, :release_boundary)
      clean = clean_record(context.runtime, handle)
      assert clean.result.exit_code == 7 and clean.state == :completed
      assert clean.fingerprint == before.fingerprint and clean.machine_name == before.machine_name
      assert Runtime.coordinator(context.runtime) == coordinator
      assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
      assert ManagedPeer.snapshot(context.peer).machines == %{}
    end
  end

  test "span failures preserve original exceptions and never include their reasons in events" do
    attach(:forward)
    table = Dispatcher.table()
    start_supervised!({Dispatcher, table: table, max_pending: 16, timeout_ms: 100})

    assert_raise RuntimeError, "private-failure-reason", fn ->
      Telemetry.span(table, :execution, {"scope", "request"}, fn ->
        raise "private-failure-reason"
      end)
    end

    assert_receive {:event, [:smolbox, :stage, :start], _, %{outcome: :pending}}
    assert_receive {:event, [:smolbox, :stage, :stop], %{duration_ms: duration}, metadata}
    assert duration >= 0 and metadata.outcome == :exception
    refute inspect(metadata) =~ "private-failure-reason"

    assert catch_throw(
             Telemetry.span(table, :cleanup, {"scope", "request"}, fn -> throw(:original) end)
           ) == :original

    assert {:error, :original} =
             Telemetry.span(table, :collection, {"scope", "request"}, fn ->
               {:error, :original}
             end)

    assert :original = Telemetry.span(nil, :unknown, :invalid, fn -> :original end)
  end

  test "malformed diagnostic records and raw error fields cannot leak through the projection" do
    attach(:forward)
    table = Dispatcher.table()
    start_supervised!({Dispatcher, table: table, max_pending: 16, timeout_ms: 100})
    record = %{Contract.record() | version: "private-version"}
    assert :ok = Telemetry.store_result(table, :accept, [], {:ok, record, :inserted})
    assert :ok = Telemetry.store_result(table, :write, [], {:ok, %{private: "payload"}})

    assert :ok =
             Telemetry.store_result(
               table,
               :write,
               [],
               {:error, %Error{category: "private-error", operation: "private-operation"}}
             )

    assert_receive {:event, [:smolbox, :store, :error], %{count: 1},
                    %{category: :unknown, operation: :write}}

    refute_receive {:event, [:smolbox, :execution, :accepted], _, _}, 50
  end

  def capture(name, measurements, metadata, {observer, mode}) do
    send(observer, {:event, name, measurements, metadata})

    if mode == :block do
      receive do
        :release -> :ok
      end
    end
  end

  defp attach(mode) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, Telemetry.events(), &__MODULE__.capture/4, {self(), mode})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp collect_cleanup(events \\ []) do
    receive do
      {:event, name, measurements, metadata} ->
        events = [{name, measurements, metadata} | events]

        if name == [:smolbox, :stage, :stop] and metadata.stage == :cleanup,
          do: Enum.reverse(events),
          else: collect_cleanup(events)
    after
      2000 -> flunk("cleanup notification did not arrive")
    end
  end

  defp clean_record(runtime, handle, attempts \\ 200)
  defp clean_record(_runtime, _handle, 0), do: flunk("execution cleanup did not finish")

  defp clean_record(runtime, {scope, id} = handle, attempts) do
    {:ok, record} = SmolBox.fetch(runtime, scope, id)

    if record.cleanup == :complete and record.reservation == nil do
      record
    else
      receive do
      after
        10 -> clean_record(runtime, handle, attempts - 1)
      end
    end
  end
end
