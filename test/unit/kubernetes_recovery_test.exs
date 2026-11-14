defmodule SmolBox.KubernetesRecoveryTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Error, Execution, Runtime, TestArtifacts}
  alias SmolBox.Kubernetes.{Assignment, Config, LabController, Receipt}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.{KubernetesInspection, Session}
  alias SmolBox.Store.Memory
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  defmodule Evidence do
    @moduledoc false
    def check(_, _, peer),
      do:
        {:ok,
         %{
           complete_history: true,
           idle: Agent.get(peer, &is_nil(&1.pod)),
           observer_epoch: "observer-epoch"
         }}

    def capture(binding, uid, _, _),
      do:
        {:ok,
         %{Fixture.observation(binding, uid) | observed_at_ms: System.system_time(:millisecond)}}

    def cleanup(_, receipt, _, peer) do
      if Agent.get(peer, &is_nil(&1.pod)),
        do:
          {:ok,
           %{Fixture.cleanup_proof(receipt) | observed_at_ms: System.system_time(:millisecond)}},
        else: {:error, %Error{category: :cleanup, operation: :cleanup}}
    end
  end

  defmodule ScanStore do
    @moduledoc false
    @behaviour SmolBox.Store
    for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks) do
      arguments = Macro.generate_arguments(arity - 1, __MODULE__)
      @impl true
      def unquote(operation)(context, unquote_splicing(arguments)),
        do: invoke(context, unquote(operation), [unquote_splicing(arguments)])
    end

    defp invoke(c, :backend_assignments, args) do
      if Agent.get(c.gate, & &1),
        do: {:error, %Error{category: :store, operation: :backend_assignments}},
        else: apply(Memory, :backend_assignments, [c.store | args])
    end

    defp invoke(c, operation, args), do: apply(Memory, operation, [c.store | args])
  end

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-recovery-tls-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tls: SmolBox.TestTLS.create(root)}
  end

  setup c do
    {kube, peer} = Peer.start(c.tls)

    root =
      Path.join(
        System.tmp_dir!(),
        "smolbox-recovery-controller-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(root)
    executable = Path.join(root, "controller-peer")
    File.cp!("test/support/kubernetes_node_peer.py", executable)
    File.chmod!(executable, 0o700)

    on_exit(fn ->
      if runtime = Process.whereis(__MODULE__), do: Supervisor.stop(runtime, :normal, 5000)
      File.rm_rf!(root)
    end)

    {:ok, guard} =
      LabController.new(directory: "/private/fixture-controller", python_executable: executable)

    kube = %{kube | controller_guard: guard, node_evidence: {Evidence, peer}}
    store = start_supervised!({Memory, []})
    artifacts = start_supervised!({Agent, fn -> %{} end}, id: :artifacts)
    gate = start_supervised!({Agent, fn -> false end}, id: :scan)
    %{kube: kube, peer: peer, root: root, store: store, artifacts: artifacts, gate: gate}
  end

  defp start(c, enrolled, owners) do
    File.write!(
      Path.join(c.root, "response.json"),
      Jason.encode!(%{
        mode: "controller",
        controller: %{enrolled: enrolled, known_owners: owners}
      })
    )

    options = [
      name: __MODULE__,
      namespace: "kubefiles",
      mode: :ephemeral,
      store: {ScanStore, %{store: c.store, gate: c.gate}},
      artifact_store: {TestArtifacts, c.artifacts},
      workers: [c.kube],
      fingerprint_key: String.duplicate("k", 32),
      poll_ms: 20,
      lease_ms: 5000
    ]

    runtime = start_supervised!({SmolBox, options})

    on_exit(fn ->
      if Process.alive?(runtime), do: Supervisor.stop(runtime, :normal, 5000)
    end)

    runtime
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(_, 0), do: flunk("recovery condition not reached")

  defp eventually(function, attempts) do
    if function.(),
      do: :ok,
      else:
        (
          Process.sleep(30)
          eventually(function, attempts - 1)
        )
  end

  defp worker_status(runtime) do
    {:ok, reports} = GenServer.call(Runtime.coordinator(runtime), :workers)
    hd(reports).status
  end

  defp seed(c, owner, state) do
    now = System.system_time(:millisecond) - 2000
    {prepared, assignment} = Fixture.ready_record(c.kube, [], now)
    record = Fixture.execution(c.kube, [], now)
    {:ok, _} = Memory.bind_backend(c.store, c.kube.id, Config.binding(c.kube))
    {:ok, _} = Memory.claim_worker(c.store, c.kube.id, owner, now, 1000)
    {:ok, _, :inserted} = Memory.accept(c.store, record, 10)
    {:ok, record} = Memory.claim(c.store, Execution.key(record), owner, now, 1000)

    {:ok, record} =
      Memory.reserve(
        c.store,
        Execution.key(record),
        Session.guard(record),
        {c.kube.id, assignment.pod_name, c.kube.capacity, assignment},
        now
      )

    {:ok, created} = Receipt.created(assignment, "pod-original")

    {:ok, record} =
      Memory.write(
        c.store,
        Execution.key(record),
        Session.guard(record),
        [backend_create_state: :dispatched, backend_receipt: created],
        now
      )

    {:ok, record} =
      Memory.write(
        c.store,
        Execution.key(record),
        Session.guard(record),
        [
          backend_receipt: prepared.backend_receipt,
          created_machine: prepared.created_machine,
          state: :ready
        ],
        now
      )

    record =
      if state == :dispatching do
        {:ok, value} =
          Memory.write(
            c.store,
            Execution.key(record),
            Session.guard(record),
            [state: :dispatching, evidence: :dispatch_uncertain],
            now
          )

        value
      else
        record
      end

    Peer.change(c.peer, &%{&1 | pod: Peer.effective(Assignment.manifest(assignment), true)})
    record
  end

  test "inspection reports an absent charged assignment as unresolved without mutation", c do
    record = seed(c, "owner-previous", :ready)
    Agent.update(c.gate, fn _ -> true end)
    runtime = start(c, true, ["owner-previous"])
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    [target] = config.workers
    config = %{config | store: {Memory, c.store}}
    Peer.change(c.peer, &%{&1 | pod: nil})
    assert {:ok, report} = KubernetesInspection.page(config, target, [])
    assert [%{status: :unresolved, observed_state: :missing}] = report.candidates
    assert report.namespace_count == 0
    assert {:ok, ^record} = Memory.fetch(c.store, Execution.key(record))
    refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
  end

  test "public submit and await save a real exit before proof-bound release", c do
    Peer.change(c.peer, &%{&1 | ready: true})

    ExecPeer.install(c.peer, %{machine_name: :any}, [
      {:binary, <<1, "SBK1", 0::32, 0, 255>>},
      ExecPeer.status(7)
    ])

    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    spec = Fixture.execution(c.kube).spec
    assert {:ok, handle} = SmolBox.submit(runtime, spec)
    assert {:ok, finished} = SmolBox.await(runtime, handle, 5000)
    assert finished.result.exit_code == 7 and finished.result.stdout == <<0, 255>>

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "public cancellation after dispatch preserves uncertainty and never replays", c do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, [], mode: :hold)
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    assert {:ok, {scope, id} = handle} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)
    eventually(fn -> Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) end)
    assert {:ok, _} = SmolBox.cancel(runtime, scope, id)

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    assert {:ok, %{state: :unknown, result: nil, evidence: :termination_confirmed}} =
             Memory.fetch(c.store, handle)

    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "public lost exit status remains unknown after positive cleanup", c do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, [{:binary, <<1, "SBK1", 0::32, "observed">>}])
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    assert {:ok, handle} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    assert {:ok, %{state: :unknown, result: nil}} = Memory.fetch(c.store, handle)
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
  end

  test "public lost POST response reconciles without a second create or exec", c do
    Peer.change(c.peer, &%{&1 | ready: true, mode: :lost_create})
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    assert {:ok, handle} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    assert {:ok, %{state: :failed}} = Memory.fetch(c.store, handle)
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
  end

  test "draining preserves accepted intent and cancellation sends no create", c do
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    assert :ok = SmolBox.drain_worker(runtime, c.kube.id)
    assert {:ok, {scope, id} = handle} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)
    Process.sleep(100)
    assert {:ok, %{state: :accepted}} = Memory.fetch(c.store, handle)
    assert {:ok, _} = SmolBox.cancel(runtime, scope, id)

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
  end

  test "empty authenticated corpus activates the controller and opens the authority fence", c do
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    assert hd(config.workers).kubernetes_config.controller_guard.enrolled
    assert Config.binding(hd(config.workers).kubernetes_config) == Config.binding(c.kube)
    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "POST"))
  end

  test "reset host ledger with an existing corpus stays frozen without changing a record", c do
    record = seed(c, "owner-previous", :dispatching)
    runtime = start(c, false, ["owner-previous"])

    eventually(fn ->
      Peer.requests(c.peer) != [] or worker_status(runtime) == :unavailable
    end)

    Process.sleep(100)
    assert {:ok, ^record} = Memory.fetch(c.store, Execution.key(record))
    assert worker_status(runtime) == :unavailable
    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "DELETE"))
  end

  test "unknown historical owner is not adopted even with a valid binding", c do
    record = seed(c, "owner-stranger", :dispatching)
    runtime = start(c, true, ["owner-previous"])
    Process.sleep(150)
    assert {:ok, ^record} = Memory.fetch(c.store, Execution.key(record))
    assert worker_status(runtime) == :unavailable
    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "DELETE"))
  end

  test "startup scan failure prevents ready execution until the complete scan succeeds", c do
    record = seed(c, "owner-previous", :ready)
    ExecPeer.install(c.peer, record, [{:binary, <<1, "SBK1", 0::32>>}, ExecPeer.status(0)])
    Agent.update(c.gate, fn _ -> true end)
    runtime = start(c, true, ["owner-previous"])
    Process.sleep(100)
    assert {:ok, ^record} = Memory.fetch(c.store, Execution.key(record))
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
    Agent.update(c.gate, fn _ -> false end)

    eventually(fn ->
      match?(
        {:ok, %{cleanup: :complete, reservation: nil}},
        Memory.fetch(c.store, Execution.key(record))
      )
    end)

    assert {:ok, finished} = Memory.fetch(c.store, Execution.key(record))
    assert finished.result.exit_code == 0
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
    assert worker_status(runtime) in [:ready, :unavailable]
  end

  test "dispatched recovery becomes unknown, deletes only the original and never re-execs", c do
    record = seed(c, "owner-previous", :dispatching)
    runtime = start(c, true, ["owner-previous"])

    eventually(fn ->
      match?(
        {:ok, %{cleanup: :complete, reservation: nil}},
        Memory.fetch(c.store, Execution.key(record))
      )
    end)

    assert {:ok, finished} = Memory.fetch(c.store, Execution.key(record))
    assert finished.state == :unknown and finished.evidence == :termination_confirmed
    assert finished.result == nil
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "DELETE")) == 1
    eventually(fn -> worker_status(runtime) == :ready end)
  end
end
