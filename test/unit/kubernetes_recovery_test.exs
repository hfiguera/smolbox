defmodule SmolBox.KubernetesRecoveryTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Error, Execution, Runtime, TestArtifacts}
  alias SmolBox.Kubernetes.{Assignment, Config, LabController, Receipt}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.{KubernetesInspection, Session, Target}
  alias SmolBox.Store.Memory
  alias SmolBox.Test.Kubernetes, as: Fixture
  @moduletag capture_log: true

  defmodule GatedArtifacts do
    @moduledoc false
    @behaviour SmolBox.ArtifactStore
    @impl true
    def read(context, scope, reference, max),
      do: TestArtifacts.read(context.store, scope, reference, max)

    @impl true
    def put(context, key, destination, bytes, digest) do
      send(context.owner, {:publishing, self()})

      receive do
        :publish -> TestArtifacts.put(context.store, key, destination, bytes, digest)
      end
    end
  end

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

    def capture(binding, uid, budget, _) do
      observation =
        %{Fixture.observation(binding, uid) | observed_at_ms: System.system_time(:millisecond)}

      # The real framed node transport must fit at least this observation payload.
      if byte_size(Jason.encode!(Map.from_struct(observation))) + 8 <= budget.max_response_bytes,
        do: {:ok, observation},
        else: {:error, %Error{category: :identity_conflict, operation: :worker}}
    end

    def cleanup(_, receipt, _, peer) do
      if Agent.get(peer, &(is_nil(&1.pod) and &1.mode != :proof_unavailable)),
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

    defp invoke(c, :backend_assignments, [_, cursor, _] = args) do
      action =
        Agent.get_and_update(c.gate, fn
          {:after_cursor, callback} = pending ->
            if cursor, do: {callback, false}, else: {false, pending}

          value ->
            {value, value}
        end)

      if is_function(action, 0), do: action.()

      if action == true,
        do: {:error, %Error{category: :store, operation: :backend_assignments}},
        else: apply(Memory, :backend_assignments, [c.store | args])
    end

    defp invoke(c, :claim_worker, args) do
      if Agent.get(c.lease_gate, & &1),
        do: {:error, %Error{category: :store, operation: :claim_worker}},
        else: apply(Memory, :claim_worker, [c.store | args])
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
      # A closed Port's OS fixture may still finish a file write. Move its
      # private directory first so late writes cannot race recursive deletion.
      closed = root <> "-closed"
      File.rename!(root, closed)
      File.rm_rf!(closed)
    end)

    {:ok, guard} =
      LabController.new(directory: "/private/fixture-controller", python_executable: executable)

    kube = %{kube | controller_guard: guard, node_evidence: {Evidence, peer}}
    store = start_supervised!({Memory, []})
    artifacts = start_supervised!({Agent, fn -> %{} end}, id: :artifacts)
    gate = start_supervised!({Agent, fn -> false end}, id: :scan)
    lease_gate = start_supervised!({Agent, fn -> false end}, id: :lease)

    %{
      kube: kube,
      peer: peer,
      root: root,
      store: store,
      artifacts: artifacts,
      gate: gate,
      lease_gate: lease_gate
    }
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
      store: {ScanStore, %{store: c.store, gate: c.gate, lease_gate: c.lease_gate}},
      artifact_store: Map.get(c, :artifact_store, {TestArtifacts, c.artifacts}),
      workers: [c.kube],
      fingerprint_key: String.duplicate("k", 32),
      poll_ms: 20,
      lease_ms: Map.get(c, :lease_ms, 5000)
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

  defp output_cap(c, cap) do
    profile = %{hd(c.kube.profiles) | max_output_bytes: cap}

    # Real Node responses include metadata that is unrelated to command output.
    Peer.change(c.peer, fn state ->
      put_in(state.objects.node["metadata"]["annotations"], %{
        "fixture.example/node-metadata" => String.duplicate("n", 4096)
      })
    end)

    %{c | kube: %{c.kube | profiles: [profile]}}
  end

  defp public_execution(c, frames) do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, frames)
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    assert {:ok, handle} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, handle))
    end)

    assert {:ok, finished} = Memory.fetch(c.store, handle)
    assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
    finished
  end

  defp seed(c, owner, state, now \\ System.system_time(:millisecond) - 2000) do
    overrides = Map.get(c, :spec_overrides, [])
    {prepared, assignment} = Fixture.ready_record(c.kube, overrides, now)
    record = Fixture.execution(c.kube, overrides, now)
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

  defp collecting(c) do
    output = %{"destination" => "output", "path" => "/workspace/output", "max_bytes" => 1024}

    c =
      Map.merge(c, %{
        spec_overrides: [outputs: [output]],
        artifact_store: {GatedArtifacts, %{store: c.artifacts, owner: self()}}
      })

    record = seed(c, "owner-previous", :dispatching)

    {:ok, record} =
      Memory.write(
        c.store,
        Execution.key(record),
        Session.guard(record),
        [
          state: :collecting,
          evidence: :exited,
          result: %SmolBox.Result{exit_code: 7, stdout: "", stderr: "", encoding: :bytes}
        ],
        record.updated_at_ms + 1
      )

    bytes = <<0, 255, 128>>

    ExecPeer.install(c.peer, record, fn header, _data ->
      ExecPeer.file_frames(header["operation"], header["path"], bytes)
    end)

    {c, record, bytes}
  end

  defp collected(c, runtime, original, bytes) do
    eventually(fn ->
      match?(
        {:ok, %{cleanup: :complete, reservation: nil}},
        Memory.fetch(c.store, Execution.key(original))
      )
    end)

    assert {:ok, finished} = Memory.fetch(c.store, Execution.key(original))
    assert finished.state == :completed and finished.collection == :complete
    assert finished.result == original.result
    assert finished.deadlines.collection == original.deadlines.collection
    assert [%{"size" => 3}] = finished.artifacts
    assert finished.backend_cleanup.version == 3
    assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)

    assert Agent.get(c.artifacts, &Map.fetch!(&1, {Execution.key(original), "output"})) ==
             {bytes, SmolBox.Files.sha256(bytes)}

    refute Enum.any?(Peer.requests(c.peer), &(&1.method == "POST"))
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "DELETE")) == 1
    eventually(fn -> worker_status(runtime) == :ready end)
  end

  @tag :recovery_lease
  test "restart collection survives the worker lease while renewal and admission continue", c do
    {c, record, bytes} = collecting(c)
    runtime = start(c, true, ["owner-previous"])
    assert_receive {:publishing, publisher}, 3000
    initial_lease = :sys.get_state(c.store).leases[c.kube.id]

    assert {:ok, queued} =
             SmolBox.submit(runtime, %{record.spec | id: "queued-during-recovery", outputs: []})

    Process.sleep(5250)
    assert Process.alive?(publisher)
    renewed = :sys.get_state(c.store).leases[c.kube.id]
    assert renewed.until_ms > initial_lease.until_ms
    assert renewed.until_ms > System.system_time(:millisecond)

    assert {:ok, %{state: :collecting, artifacts: [], reservation: reservation}} =
             Memory.fetch(c.store, Execution.key(record))

    assert reservation != nil
    assert {:ok, %{state: :accepted, reservation: nil}} = Memory.fetch(c.store, queued)
    assert worker_status(runtime) == :unavailable
    refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
    assert {:ok, _} = SmolBox.cancel(runtime, elem(queued, 0), elem(queued, 1))

    send(publisher, :publish)
    collected(c, runtime, record, bytes)
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 1
    refute_receive {:publishing, _}, 20
  end

  test "a failed background recovery is retried with the target still fenced", c do
    {c, record, bytes} = collecting(c)
    runtime = start(c, true, ["owner-previous"])
    assert_receive {:publishing, publisher}, 3000
    monitor = Process.monitor(publisher)
    coordinator = Runtime.coordinator(runtime)
    {recovery, _} = :sys.get_state(coordinator).native_holders[c.kube.id]
    Process.exit(recovery, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 1000
    assert_receive {:publishing, replacement}, 3000
    assert replacement != publisher
    assert worker_status(runtime) == :unavailable
    refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
    send(replacement, :publish)
    collected(c, runtime, record, bytes)
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 2
  end

  test "failed lease renewal stops recovery IO before publishing or deleting", c do
    {c, record, bytes} = collecting(Map.put(c, :lease_ms, 1000))
    runtime = start(c, true, ["owner-previous"])
    assert_receive {:publishing, publisher}, 3000
    monitor = Process.monitor(publisher)
    Agent.update(c.lease_gate, fn _ -> true end)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 3000
    assert worker_status(runtime) == :unavailable

    assert {:ok, %{state: :collecting, artifacts: [], reservation: reservation}} =
             Memory.fetch(c.store, Execution.key(record))

    assert reservation != nil
    refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
    assert Agent.get(c.artifacts, &map_size/1) == 0
    Agent.update(c.lease_gate, fn _ -> false end)
    assert_receive {:publishing, replacement}, 3000
    send(replacement, :publish)
    collected(c, runtime, record, bytes)
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

  for cap <- [1, 4096] do
    test "public silent execution keeps infrastructure headroom with output cap #{cap}", c do
      c = output_cap(c, unquote(cap))
      assert :ok = Config.validate(c.kube)

      finished = public_execution(c, [{:binary, <<1, "SBK1", 0::32>>}, ExecPeer.status(0)])

      assert finished.state == :completed
      assert finished.last_error == nil
      assert %{exit_code: 0, stdout: "", stderr: "", truncated: false} = finished.result
    end
  end

  test "public execution retains the full combined output cap after control traffic", c do
    c = output_cap(c, 4096)
    stdout = :binary.copy(<<255>>, 2048)
    stderr = :binary.copy(<<254>>, 2048)

    finished =
      public_execution(c, [
        {:binary, <<1, "SBK1", 0::32, stdout::binary>>},
        {:binary, <<2, stderr::binary>>},
        ExecPeer.status(7)
      ])

    assert finished.state == :completed
    assert finished.last_error == nil
    assert finished.result.exit_code == 7
    assert finished.result.stdout == stdout
    assert finished.result.stderr == stderr
    refute finished.result.truncated
  end

  test "public execution still rejects combined output above the cap", c do
    c = output_cap(c, 4096)
    stdout = :binary.copy(<<255>>, 4096)

    finished =
      public_execution(c, [
        {:binary, <<1, "SBK1", 0::32, stdout::binary>>},
        {:binary, <<2, 254>>},
        ExecPeer.status(0)
      ])

    assert finished.state == :unknown
    assert finished.last_error.category == :output_limit
    assert finished.result == nil
  end

  test "a busy single-slot target queues valid work and executes it after release", c do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, [], mode: :hold)
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    spec = Fixture.execution(c.kube).spec
    assert {:ok, first} = SmolBox.submit(runtime, %{spec | id: "queue-first"})
    eventually(fn -> Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) end)
    assert {:ok, %{slots: 1}} = Memory.usage(c.store, c.kube.id)

    assert {:ok, second} = SmolBox.submit(runtime, %{spec | id: "queue-second"})

    eventually(fn ->
      {:ok, record} = Memory.fetch(c.store, second)
      record.state != :accepted or record.next_due_at_ms > record.accepted_at_ms
    end)

    assert {:ok, %{state: :accepted, reservation: nil, last_error: nil} = queued} =
             Memory.fetch(c.store, second)

    assert queued.next_due_at_ms > queued.accepted_at_ms
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 1

    ExecPeer.install(c.peer, %{machine_name: :any}, [
      {:binary, <<1, "SBK1", 0::32>>},
      ExecPeer.status(0)
    ])

    assert {:ok, _} = SmolBox.cancel(runtime, elem(first, 0), elem(first, 1))

    eventually(fn ->
      match?({:ok, %{cleanup: :complete, reservation: nil}}, Memory.fetch(c.store, second))
    end)

    assert {:ok, %{state: :completed, result: %{exit_code: 0}}} = Memory.fetch(c.store, second)
    assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)
    assert Enum.count(Peer.requests(c.peer), &(&1.method == "POST")) == 2
    assert Enum.count(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec")) == 2
  end

  test "creation qualification preserves transient health errors", c do
    runtime = start(c, false, [])
    eventually(fn -> worker_status(runtime) == :ready end)
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    [target] = config.workers
    Peer.change(c.peer, &put_in(&1.objects.version["gitVersion"], "unavailable-version"))

    assert {:error, %{category: :identity_conflict, operation: :worker}} =
             Target.qualify(target, Fixture.execution(c.kube).spec)
  end

  for {cause, outcome} <- [cancelled: :cancelled, expired: :failed] do
    @tag recovery_cause: cause, recovery_outcome: outcome
    test "#{cause} ready recovery cleans the absent original without dispatch", c do
      age =
        if c.recovery_cause == :expired, do: hd(c.kube.profiles).preparation_ms + 2000, else: 2000

      record = seed(c, "owner-previous", :ready, System.system_time(:millisecond) - age)

      if c.recovery_cause == :cancelled,
        do: Memory.cancel(c.store, Execution.key(record), System.system_time(:millisecond))

      Peer.change(c.peer, &%{&1 | pod: nil})
      runtime = start(c, true, ["owner-previous"])

      eventually(fn ->
        match?(
          {:ok, %{cleanup: :complete, reservation: nil}},
          Memory.fetch(c.store, Execution.key(record))
        )
      end)

      assert {:ok, finished} = Memory.fetch(c.store, Execution.key(record))
      assert finished.state == c.recovery_outcome and finished.result == nil
      assert finished.deadlines.preparation == record.deadlines.preparation
      assert finished.backend_cleanup.version == 3
      assert finished.backend_cleanup.receipt == record.backend_receipt
      assert {:ok, %{slots: 0}} = Memory.usage(c.store, c.kube.id)
      refute Enum.any?(Peer.requests(c.peer), &(&1.method in ["POST", "DELETE"]))
      refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
      eventually(fn -> worker_status(runtime) == :ready end)
    end
  end

  test "cancelled ready recovery retains its reservation until node proof arrives", c do
    record = seed(c, "owner-previous", :ready)
    {:ok, _} = Memory.cancel(c.store, Execution.key(record), System.system_time(:millisecond))
    Peer.change(c.peer, &%{&1 | pod: nil, mode: :proof_unavailable})
    runtime = start(c, true, ["owner-previous"])

    eventually(fn ->
      {:ok, current} = Memory.fetch(c.store, Execution.key(record))
      current.state == :cancelled and current.cleanup_attempts > 0
    end)

    assert {:ok, %{slots: 1}} = Memory.usage(c.store, c.kube.id)
    assert worker_status(runtime) == :unavailable
    Peer.change(c.peer, &%{&1 | mode: :normal})

    eventually(fn ->
      match?(
        {:ok, %{cleanup: :complete, reservation: nil}},
        Memory.fetch(c.store, Execution.key(record))
      )
    end)

    assert {:ok, %{backend_cleanup: %{version: 3}}} = Memory.fetch(c.store, Execution.key(record))
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
    eventually(fn -> worker_status(runtime) == :ready end)
  end

  test "final startup verification observes cancellation after an earlier ready page", c do
    record = seed(c, "owner-previous", :ready)
    marker = Fixture.execution(c.kube, id: "z-paging-marker", scope: record.scope)
    {:ok, _, :inserted} = Memory.accept(c.store, marker, 10)
    {:ok, _} = Memory.cancel(c.store, Execution.key(marker), System.system_time(:millisecond))
    caller = self()

    Agent.update(c.gate, fn _ ->
      {:after_cursor,
       fn ->
         {:ok, _} =
           Memory.cancel(c.store, Execution.key(record), System.system_time(:millisecond))

         Peer.change(c.peer, &%{&1 | pod: nil})
         send(caller, :cancelled_between_pages)
       end}
    end)

    runtime = start(c, true, ["owner-previous"])
    assert_receive :cancelled_between_pages, 3000

    eventually(fn ->
      match?(
        {:ok, %{state: :cancelled, cleanup: :complete, reservation: nil}},
        Memory.fetch(c.store, Execution.key(record))
      )
    end)

    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
    eventually(fn -> worker_status(runtime) == :ready end)
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
