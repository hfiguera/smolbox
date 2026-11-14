defmodule SmolBox.KubernetesRuntimeLifecycleTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, Execution, Result, TestArtifacts}
  alias SmolBox.Kubernetes.Assignment
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.{Cleanup, Executor, KubernetesPreparation, Session}
  alias SmolBox.Store.Memory
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  defmodule Evidence do
    @moduledoc false
    def check(_, _, _), do: {:error, :not_enabled}

    def capture(binding, uid, _, context) do
      send(context.owner, {:node_capture, uid})

      mode =
        Agent.get_and_update(context.mode, fn
          :capture_pending -> {:capture_pending, :ok}
          value -> {value, value}
        end)

      if mode == :capture_pending,
        do: {:error, %Error{category: :identity_conflict, operation: :worker}},
        else:
          {:ok,
           %{Fixture.observation(binding, uid) | observed_at_ms: System.system_time(:millisecond)}}
    end

    def cleanup(_, receipt, _, context) do
      send(context.owner, {:physical_proof, receipt.pod_uid})

      case Agent.get(context.mode, & &1) do
        :unavailable ->
          {:error, %Error{category: :identity_conflict, operation: :cleanup}}

        :legacy ->
          {:ok,
           %{
             Fixture.cleanup_proof(receipt)
             | version: 1,
               observed_at_ms: System.system_time(:millisecond)
           }}

        :stale ->
          {:ok,
           %{Fixture.cleanup_proof(receipt) | observed_at_ms: receipt.observation.observed_at_ms}}

        :ok ->
          {:ok,
           %{Fixture.cleanup_proof(receipt) | observed_at_ms: System.system_time(:millisecond)}}
      end
    end
  end

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-lifecycle-tls-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tls: SmolBox.TestTLS.create(root)}
  end

  setup c do
    {kube, peer} = Peer.start(c.tls)
    store = start_supervised!({Memory, []})
    artifacts = start_supervised!({Agent, fn -> %{} end}, id: :artifacts)
    mode = start_supervised!({Agent, fn -> :ok end}, id: :evidence)
    profile = %{hd(kube.profiles) | cleanup_ms: Map.get(c, :cleanup_ms, 30_000)}
    kube = %{kube | profiles: [profile], node_evidence: {Evidence, %{owner: self(), mode: mode}}}
    now = System.system_time(:millisecond)
    prepared = Fixture.assigned(kube, [], now)
    {config, record} = Fixture.runtime(kube, store, {TestArtifacts, artifacts}, prepared)
    Peer.change(peer, &%{&1 | ready: true})

    %{
      kube: kube,
      peer: peer,
      store: store,
      config: config,
      record: record,
      session: Session.new(config, record),
      mode: mode
    }
  end

  defp ready(c) do
    {:ok, record} = KubernetesPreparation.prepare(c.session, c.record)
    %{c | record: record}
  end

  defp fail(c) do
    {:ok, record} =
      Session.patch(c.session,
        state: :failed,
        last_error: %Error{category: :unknown, operation: :create}
      )

    %{c | record: record}
  end

  defp fetched(c), do: Memory.fetch(c.store, Execution.key(c.record))
  defp methods(c), do: Peer.requests(c.peer) |> Enum.map(& &1.method)

  test "preparation persists original UID and node incarnation before readiness", c do
    c = ready(c)
    assert c.record.state == :ready
    assert c.record.backend_create_state == :dispatched
    assert c.record.backend_receipt.phase == :ready
    assert c.record.backend_receipt.pod_uid == "pod-original"
    assert c.record.created_machine.backend_identity.receipt == c.record.backend_receipt
    assert_receive {:node_capture, "pod-original"}
    assert Enum.count(methods(c), &(&1 == "POST")) == 1
  end

  test "API readiness waits for a first complete guard capture without another POST", c do
    deadline = c.record.deadlines.preparation
    Agent.update(c.mode, fn _ -> :capture_pending end)
    c = ready(c)
    assert c.record.deadlines.preparation == deadline
    assert_receive {:node_capture, "pod-original"}
    assert_receive {:node_capture, "pod-original"}
    assert Enum.count(methods(c), &(&1 == "POST")) == 1
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "never-dispatched cancellation releases without any backend request", c do
    {:ok, _} = Memory.cancel(c.store, Execution.key(c.record), System.system_time(:millisecond))
    {:ok, _} = Session.patch(c.session, state: :cancelled)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.cleanup == :complete and cleaned.backend_cleanup == :not_dispatched
    assert cleaned.reservation == nil and cleaned.backend_create_state == :pending
    assert Peer.requests(c.peer) == []
    refute_receive {:physical_proof, _}
  end

  test "UID deletion and fresh physical proof persist before reservation release", c do
    c = c |> ready() |> fail()
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.cleanup == :complete and cleaned.reservation == nil
    assert cleaned.backend_cleanup.receipt == cleaned.backend_receipt
    assert cleaned.absence_at_ms == cleaned.backend_cleanup.observed_at_ms
    assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)
    assert_receive {:physical_proof, "pod-original"}
    assert Enum.count(methods(c), &(&1 == "DELETE")) == 1
    assert {:ok, _} = Cleanup.run(c.session)
    assert Enum.count(methods(c), &(&1 == "DELETE")) == 1
  end

  test "API absence with an unavailable proof keeps capacity and original exit", c do
    c = ready(c)
    {:ok, _} = Session.patch(c.session, state: :dispatching, evidence: :dispatch_uncertain)
    result = %Result{exit_code: 7, stdout: <<0, 255>>, stderr: "", encoding: :bytes}
    {:ok, _} = Session.patch(c.session, state: :collecting, evidence: :exited, result: result)
    {:ok, _} = Session.patch(c.session, state: :collection_failed, collection: :failed)
    Agent.update(c.mode, fn _ -> :unavailable end)
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.result == result and held.backend_cleanup == nil
    assert held.cleanup == :in_progress and held.reservation != nil
    assert {:ok, %{slots: 1}} = Memory.usage(c.store, c.kube.id)
    Agent.update(c.mode, fn _ -> :ok end)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.result == result and cleaned.reservation == nil
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "lost create response is reconciled once without a second POST or application exec", c do
    Peer.change(c.peer, &%{&1 | mode: :lost_create})
    assert {:error, _} = KubernetesPreparation.prepare(c.session, c.record)
    assert {:ok, ambiguous} = fetched(c)
    assert ambiguous.backend_create_state == :dispatched and ambiguous.backend_receipt == nil
    c = fail(c)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.reservation == nil and cleaned.backend_receipt.pod_uid == "pod-original"
    assert Enum.count(methods(c), &(&1 == "POST")) == 1
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "ambiguous create followed by API absence cannot release an unobserved attempt", c do
    {:ok, _} = Session.patch(c.session, backend_create_state: :dispatched)
    c = fail(c)
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.backend_receipt == nil and held.backend_cleanup == nil
    assert held.reservation != nil
    refute "POST" in methods(c)
    refute "DELETE" in methods(c)
    refute_receive {:physical_proof, _}
  end

  test "foreign replacement survives and blocks release", c do
    c = c |> ready() |> fail()
    Peer.change(c.peer, &put_in(&1.pod["metadata"]["uid"], "foreign-replacement"))
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.reservation != nil and held.last_error.category == :identity_conflict
    refute "DELETE" in methods(c)
    refute_receive {:physical_proof, _}
  end

  test "a component-only proof cannot complete managed cleanup", c do
    c = c |> ready() |> fail()
    Agent.update(c.mode, fn _ -> :legacy end)
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.reservation != nil and held.backend_cleanup == nil
    Agent.update(c.mode, fn _ -> :ok end)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.reservation == nil
  end

  test "stale proof is refused and a later fresh observation can complete", c do
    c = c |> ready() |> fail()
    Process.sleep(2)
    Agent.update(c.mode, fn _ -> :stale end)
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.reservation != nil and held.backend_cleanup == nil
    Agent.update(c.mode, fn _ -> :ok end)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.reservation == nil
  end

  test "cancelled ready work deletes its original Pod without dispatching the application", c do
    c = ready(c)
    {:ok, _} = Memory.cancel(c.store, Execution.key(c.record), System.system_time(:millisecond))
    assert {:ok, cleaned} = Executor.run(c.config, Execution.key(c.record), [])
    assert cleaned.state == :cancelled and cleaned.evidence == :not_dispatched
    assert cleaned.reservation == nil
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "exhausted cleanup only observes positive proof and never resets its deadline", c do
    c = %{c | config: %{c.config | cleanup_attempts: 1}}
    c = %{c | session: Session.new(c.config, c.record)}
    c = c |> ready() |> fail()
    Agent.update(c.mode, fn _ -> :unavailable end)
    assert {:ok, held} = Cleanup.run(c.session)
    deadline = held.deadlines.cleanup
    assert held.cleanup == :failed and held.reservation != nil
    deletes = Enum.count(methods(c), &(&1 == "DELETE"))
    Agent.update(c.mode, fn _ -> :ok end)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.reservation == nil and cleaned.deadlines.cleanup == deadline
    assert Enum.count(methods(c), &(&1 == "DELETE")) == deletes
  end

  @tag cleanup_ms: 1000
  test "after the cleanup deadline a fresh read-only proof can release without another DELETE",
       c do
    c = c |> ready() |> fail()
    Agent.update(c.mode, fn _ -> :unavailable end)
    {:ok, held} = Cleanup.run(c.session)
    deadline = held.deadlines.cleanup
    Process.sleep(max(1, deadline - System.system_time(:millisecond) + 2))
    Agent.update(c.mode, fn _ -> :ok end)
    assert {:ok, cleaned} = Cleanup.run(c.session)
    assert cleaned.reservation == nil and cleaned.deadlines.cleanup == deadline
    assert Enum.count(methods(c), &(&1 == "DELETE")) == 1
  end

  test "a rejected mutated Pod still saves its UID and is deleted without inventing readiness",
       c do
    path = "/api/v1/namespaces/smolbox-preview/pods"
    manifest = Assignment.manifest(c.record.backend_assignment)
    pod = manifest |> Peer.effective(true) |> put_in(["spec", "hostNetwork"], true)

    response = fn conn ->
      Peer.change(c.peer, &%{&1 | pod: pod})
      SmolBox.TestPeer.json(conn, pod, 201)
    end

    Peer.change(c.peer, &put_in(&1.overrides[{"POST", path}], response))

    assert {:error, %{category: :identity_conflict}} =
             KubernetesPreparation.prepare(c.session, c.record)

    assert {:ok, saved} = fetched(c)
    assert saved.backend_receipt.pod_uid == "pod-original"
    assert saved.backend_receipt.phase == :created and saved.created_machine == nil
    c = fail(c)
    assert {:ok, held} = Cleanup.run(c.session)
    assert held.reservation != nil and held.backend_cleanup == nil
    assert Enum.count(methods(c), &(&1 == "DELETE")) == 1
    assert Agent.get(c.peer, & &1.pod) == nil
    refute_receive {:physical_proof, _}
  end

  for {event, phase} <- [
        {:absence_record, :before},
        {:absence_record, :after},
        {:release, :before}
      ] do
    test "store failure at #{event}/#{phase} retains authority for a safe retry", c do
      c = c |> ready() |> fail()
      owner = self()

      faults =
        start_supervised!(
          {Agent, fn -> %{observer: owner, failure: {unquote(event), unquote(phase)}} end},
          id: :faults
        )

      config = %{c.config | store: {SmolBox.FaultStore, %{store: c.store, faults: faults}}}
      session = Session.new(config, c.record)
      _result = Cleanup.run(session)
      assert {:ok, held} = fetched(c)
      assert held.reservation != nil

      if unquote(event) == :release or unquote(phase) == :after do
        assert held.cleanup == :complete and held.backend_cleanup != nil
      else
        assert held.cleanup != :complete and held.backend_cleanup == nil
      end

      assert {:ok, cleaned} = Cleanup.run(session)
      assert cleaned.reservation == nil and cleaned.cleanup == :complete
      assert Enum.count(methods(c), &(&1 == "POST")) == 1
      assert Enum.count(methods(c), &(&1 == "DELETE")) == 1
    end
  end

  test "a different controller cannot claim or delete before quiescence is implemented", c do
    c = c |> ready() |> fail()
    config = %{c.config | owner: "owner-replacement"}

    assert {:error, %{category: :unsupported_capability, operation: :reconcile}} =
             Executor.run(config, Execution.key(c.record), [])

    assert {:ok, unchanged} = fetched(c)
    assert unchanged == c.record
    refute "DELETE" in methods(c)
    refute_receive {:physical_proof, _}
  end

  test "restart classification of dispatched work never invokes exec or synthetic stop", c do
    c = ready(c)
    {:ok, _} = Session.patch(c.session, state: :dispatching, evidence: :dispatch_uncertain)
    assert {:ok, cleaned} = Executor.run(c.config, Execution.key(c.record), [])
    assert cleaned.state == :unknown and cleaned.evidence == :termination_confirmed
    assert cleaned.reservation == nil and cleaned.result == nil
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end
end
