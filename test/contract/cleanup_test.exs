defmodule SmolBox.CleanupTest do
  use ExUnit.Case, async: false

  alias SmolBox.{Client, MachineSpec, ManagedPeer, Result, Runtime, RuntimeFixture}
  alias SmolBox.Runtime.{Cleanup, Config, Session}
  alias SmolBox.Store.{Contract, Memory}

  test "finished work is discarded without requiring a successful graceful stop" do
    {session, context} = prepare(:completed, stop_failure: true)
    assert {:ok, record} = Cleanup.run(session)
    assert record.cleanup == :complete
    assert record.reservation == nil
    assert record.evidence == :exited
    assert record.result.exit_code == 0
    assert record.absence_at_ms != nil
    assert ManagedPeer.snapshot(context.peer).machines == %{}
    refute stopped?(context)
  end

  test "failed graceful stop preserves unknown work and capacity during retention" do
    {session, context} = prepare(:unknown, stop_failure: true)
    assert {:ok, record} = Cleanup.run(session)
    assert record.state == :unknown
    assert record.evidence == :unknown
    assert record.reservation != nil
    assert record.absence_at_ms == nil
    assert record.last_error.operation == :stop
    assert stopped?(context)
    refute deleted?(context)
  end

  test "successful graceful stop retains unknown disks without releasing capacity" do
    {session, context} = prepare(:unknown)
    assert {:ok, record} = Cleanup.run(session)
    assert record.evidence == :termination_confirmed
    assert record.state == :unknown
    assert record.reservation != nil
    assert record.cleanup_attempts == 0
    assert stopped?(context)
    refute deleted?(context)
  end

  test "expired unknown retention permits discard without inventing an exit" do
    {session, context} = prepare(:expired_retention, stop_failure: true)
    assert {:ok, record} = Cleanup.run(session)
    assert record.state == :unknown
    assert record.result == nil
    assert record.evidence == :termination_confirmed
    assert record.cleanup == :complete
    assert record.reservation == nil
    assert record.absence_at_ms != nil
    refute stopped?(context)
    assert deleted?(context)
  end

  test "a successful delete response alone never releases capacity" do
    {session, context} = prepare(:completed, delete_retained: true)
    assert {:ok, record} = Cleanup.run(session)
    assert record.cleanup == :in_progress
    assert record.reservation != nil
    assert record.absence_at_ms == nil
    assert record.last_error.operation == :delete
    assert deleted?(context)
    assert map_size(ManagedPeer.snapshot(context.peer).machines) == 1
  end

  test "discard refuses a replacement incarnation" do
    {session, context} = prepare(:completed)

    Agent.update(context.peer, fn state ->
      %{
        state
        | machines:
            Map.new(state.machines, fn {name, machine} ->
              {name, Map.update!(machine, "createdAt", &(&1 + 1))}
            end)
      }
    end)

    assert {:ok, record} = Cleanup.run(session)
    assert record.cleanup == :failed
    assert record.reservation != nil
    assert record.last_error.category == :identity_conflict
    refute deleted?(context)
    refute stopped?(context)
  end

  test "a lost delete response retains capacity until later absence is observed" do
    {session, context} = prepare(:expired_retention, delete_lost: true)
    assert {:ok, uncertain} = Cleanup.run(session)
    assert uncertain.evidence == :unknown
    assert uncertain.reservation != nil
    assert uncertain.absence_at_ms == nil
    assert {:ok, cleaned} = Cleanup.run(session)
    assert cleaned.state == :unknown
    assert cleaned.result == nil
    assert cleaned.evidence == :termination_confirmed
    assert cleaned.reservation == nil

    assert Enum.count(
             ManagedPeer.snapshot(context.peer).operations,
             fn {method, _path} -> method == "DELETE" end
           ) == 1
  end

  test "preservation retry exhaustion never falls back to destructive disposal" do
    {session, context} = prepare(:unknown, stop_failure: true)

    for _attempt <- 1..session.config.cleanup_attempts do
      assert {:ok, _} = Cleanup.run(session)
    end

    assert {:ok, failed} = Cleanup.run(session)
    assert failed.cleanup == :failed
    assert failed.cleanup_attempts == session.config.cleanup_attempts
    assert failed.evidence == :unknown
    assert failed.reservation != nil
    refute deleted?(context)

    assert Enum.count(
             ManagedPeer.snapshot(context.peer).operations,
             fn {_method, path} -> String.ends_with?(path, "/stop") end
           ) == session.config.cleanup_attempts
  end

  defp prepare(outcome, options \\ []) do
    context = RuntimeFixture.start(options)
    stop_supervised!(Runtime)
    store = start_supervised!({Memory, []}, id: :cleanup_store)
    context = %{context | store: store}
    {:ok, config} = Config.new(Keyword.put(context.options, :store, {Memory, store}))
    now = System.system_time(:millisecond)
    accepted = if outcome == :expired_retention, do: now - 100_000, else: now
    initial = Contract.record()
    spec = %{initial.spec | retention_ms: 60_000}
    {:ok, initial} = SmolBox.Execution.new(spec, initial.fingerprint, accepted)
    key = {spec.scope, spec.id}
    {:ok, _, :inserted} = Memory.accept(context.store, initial, 10)
    {:ok, _} = Memory.claim_worker(context.store, "peer", config.owner, accepted, 900_000)
    {:ok, claimed} = Memory.claim(context.store, key, config.owner, accepted, 900_000)

    {:ok, reserved} =
      Memory.reserve(
        context.store,
        key,
        Session.guard(claimed),
        {"peer", "cleanup-owned", Contract.capacity()},
        accepted
      )

    client = hd(config.workers).client
    {:ok, machine_spec} = MachineSpec.new("cleanup-owned", "/approved/python.smolmachine")
    {:ok, machine} = Client.create(client, machine_spec)
    {:ok, _} = Client.start(client, machine.name)

    patches =
      [
        [state: :ready, created_machine: machine],
        [state: :dispatching, evidence: :dispatch_uncertain]
      ] ++ outcome_patches(outcome)

    record =
      Enum.reduce(patches, reserved, fn changes, previous ->
        {:ok, next} = Memory.write(context.store, key, Session.guard(previous), changes, accepted)
        next
      end)

    {Session.new(config, record), context}
  end

  defp outcome_patches(:completed),
    do: [
      [
        state: :collecting,
        evidence: :exited,
        result: %Result{exit_code: 0, stdout: "", stderr: ""}
      ],
      [state: :completed, collection: :complete]
    ]

  defp outcome_patches(_unknown), do: [[state: :unknown, evidence: :unknown]]

  defp stopped?(context),
    do:
      Enum.any?(
        ManagedPeer.snapshot(context.peer).operations,
        fn {_method, path} -> String.ends_with?(path, "/stop") end
      )

  defp deleted?(context),
    do:
      Enum.any?(
        ManagedPeer.snapshot(context.peer).operations,
        fn {method, _path} -> method == "DELETE" end
      )
end
