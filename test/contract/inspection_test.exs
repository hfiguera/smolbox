defmodule SmolBox.InspectionTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Error,
    Execution,
    FaultStore,
    Identity,
    Machine,
    ManagedPeer,
    Runtime,
    TestArtifacts,
    Worker
  }

  alias SmolBox.Runtime.{Config, Inspection, WorkerConfig}
  alias SmolBox.Store.{Contract, Memory}

  setup do
    {peer, port} = ManagedPeer.start()
    store = start_supervised!(Memory)

    {:ok, endpoint} =
      Worker.new("audit-worker", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)
    spec = Contract.record().spec

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        architecture: "x86_64",
        platform: :linux,
        draining: true,
        profiles: [spec.profile],
        artifacts: [Map.put(spec.artifact, "path", "/approved/private-artifact.smolmachine")],
        capacity: Contract.capacity(10)
      )

    options = [
      name: SmolBox.AuditTest,
      namespace: "audit",
      store: {Memory, store},
      mode: :ephemeral,
      artifact_store: {TestArtifacts, nil},
      fingerprint_key: :binary.copy(<<1>>, 32),
      workers: [worker]
    ]

    {:ok, config} = Config.new(options)
    %{peer: peer, store: store, config: config, options: options}
  end

  test "bounded inspection distinguishes assignment evidence without mutating worker or records",
       context do
    records =
      for status <- [:owned, :unverified, :conflict, :cleanup_conflict],
          do: assignment(context, status)

    untracked = machine(context, :candidate)
    machine(context, :foreign)
    assert {:ok, report} = Inspection.page(context.config, "audit-worker", [])
    assert report.foreign_count == 1
    assert report.next_cursor == nil

    assert Enum.sort(Enum.map(report.candidates, & &1.status)) ==
             Enum.sort([:owned, :unverified, :conflict, :cleanup_conflict, :untracked])

    assert Enum.find(report.candidates, &(&1.machine_name == untracked["name"])).status ==
             :untracked

    refute inspect(report) =~ "secret-audit-fixture"
    refute inspect(report) =~ "/approved/"

    for record <- records do
      assert {:ok, ^record} = Memory.fetch(context.store, Execution.key(record))
    end

    assert Enum.all?(ManagedPeer.snapshot(context.peer).operations, &(elem(&1, 0) == "GET"))
    assert map_size(ManagedPeer.snapshot(context.peer).machines) == 6
  end

  test "public operator API pages draining workers and rejects unbounded options", context do
    names = for _n <- 1..3, do: machine(context, :candidate)["name"]
    runtime = start_supervised!({Runtime, context.options})
    assert {:ok, first} = SmolBox.audit_worker(runtime, "audit-worker", limit: 2)
    assert [_first, _second] = first.candidates
    assert first.next_cursor != nil

    assert {:ok, second} =
             SmolBox.audit_worker(runtime, "audit-worker", limit: 2, cursor: first.next_cursor)

    assert [_third] = second.candidates
    assert second.next_cursor == nil
    assert Enum.map(first.candidates ++ second.candidates, & &1.machine_name) == Enum.sort(names)

    for options <- [[limit: 0], [limit: 101], [cursor: "../bad"], [unknown: true], nil] do
      assert {:error, %Error{category: :validation}} =
               SmolBox.audit_worker(runtime, "audit-worker", options)
    end

    assert {:error, %Error{category: :not_found}} = SmolBox.audit_worker(runtime, "absent")
    assert {:error, %Error{category: :validation}} = SmolBox.audit_worker(runtime, nil)
    assert ManagedPeer.snapshot(context.peer).commands == []
  end

  test "unavailable and slow stores cannot turn candidate names into orphan proof", context do
    machine(context, :candidate)
    parent = self()

    gate =
      start_supervised!(
        {Agent,
         fn -> %{event: :find_machine, phase: :before, observer: parent, fired: false} end},
        id: :gate
      )

    config = %{context.config | store: {FaultStore, %{store: context.store, faults: gate}}}
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{candidates: [%{status: :unavailable}]}} =
             Inspection.page(config, "audit-worker", [])

    assert System.monotonic_time(:millisecond) - started < 2000
    assert_receive {:boundary, :find_machine, :before, blocked}
    refute Process.alive?(blocked)
    stop_supervised!(Memory)

    assert {:ok, %{candidates: [%{status: :unavailable}]}} =
             Inspection.page(context.config, "audit-worker", [])

    assert Enum.all?(ManagedPeer.snapshot(context.peer).operations, &(elem(&1, 0) == "GET"))
  end

  defp assignment(context, status) do
    wire = machine(context, :candidate)
    {:ok, observed} = Machine.from_wire(wire)
    original = Contract.record(Atom.to_string(status), ["echo", "secret-audit-fixture"])
    key = Execution.key(original)
    {:ok, _lease} = Memory.claim_worker(context.store, "audit-worker", "owner", 1000, 5000)
    {:ok, _, :inserted} = Memory.accept(context.store, original, 10)
    {:ok, claimed} = Memory.claim(context.store, key, "owner", 1100, 5000)

    {:ok, reserved} =
      Memory.reserve(
        context.store,
        key,
        Contract.guard(claimed),
        {"audit-worker", wire["name"], Contract.capacity(10)},
        1100
      )

    record = record_evidence(context.store, reserved, observed, status)

    if status == :conflict do
      Agent.update(context.peer, fn state ->
        put_in(state, [:machines, wire["name"], "createdAt"], observed.created_at + 1)
      end)
    end

    record
  end

  defp record_evidence(_store, record, _observed, :unverified), do: record

  defp record_evidence(store, record, observed, status) do
    {:ok, verified} =
      Memory.write(
        store,
        Execution.key(record),
        Contract.guard(record),
        [created_machine: observed],
        1100
      )

    if status == :cleanup_conflict do
      {:ok, cleaned} =
        Memory.write(
          store,
          Execution.key(record),
          Contract.guard(verified),
          [state: :failed, cleanup: :complete, absence_at_ms: 1200],
          1200
        )

      {:ok, released} =
        Memory.release(store, Execution.key(record), Contract.guard(cleaned), 1200)

      released
    else
      verified
    end
  end

  defp machine(context, kind) do
    {:ok, generated} = Identity.machine_name("audit")
    name = if kind == :foreign, do: "foreign-machine", else: generated

    wire =
      "test/fixtures/wire/created.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("name", name)

    Agent.update(context.peer, &put_in(&1, [:machines, name], wire))
    wire
  end
end
