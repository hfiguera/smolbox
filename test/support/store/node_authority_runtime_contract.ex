defmodule SmolBox.Test.NodeAuthorityRuntimeContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Command, Execution, Files, Result, Runtime, TestArtifacts}
  alias SmolBox.Kubernetes.{Assignment, Config, GuestHelper, LabController, Receipt}
  alias SmolBox.KubernetesExecPeer, as: ExecPeer
  alias SmolBox.KubernetesPeer, as: Peer
  alias SmolBox.Runtime.Session
  alias SmolBox.Store.Codec
  alias SmolBox.Test.Kubernetes, as: Fixture
  alias SmolBox.Test.{NodeAuthorityPeer, NodeAuthorityStore}
  alias __MODULE__, as: Contract

  @executable Path.expand("../kubernetes_node_peer.py", __DIR__)

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

  defmacro __using__(options) do
    scenarios = [
      {"binary staging, read-back, exit and collection persist proof before release", :binary_io},
      {"silent zero exit works with a one-byte output cap", :tiny_output},
      {"silent zero exit works with a 4 KiB output cap", :small_output},
      {"exact combined output cap preserves real exit seven", :exact_output},
      {"excess combined output remains unknown", :excess_output},
      {"lost create response never creates or executes twice", :lost_create},
      {"lost status never replays application work", :lost_status},
      {"cancellation before admission sends no create", :cancel_queued},
      {"cancellation after dispatch keeps uncertainty", :cancel_dispatched},
      {"occupied single slot keeps accepted work queued", :occupied},
      {"changed authority generation freezes charged recovery", :changed_epoch},
      {"changed manifest freezes charged recovery", :changed_manifest},
      {"missing authority freezes charged recovery", :missing},
      {"corrupt authority freezes charged recovery", :corrupt},
      {"old lab receipts are never adopted by standalone authority", :old_lab},
      {"cancelled absent original cleans up without application dispatch", :cancel_ready},
      {"expired absent original cleans up without application dispatch", :expired_ready},
      {"complete paginated startup observes cancellation between pages", :pages},
      {"foreign inventory prevents admission", :foreign},
      {"replacement UID is preserved while original reservation stays charged", :replacement},
      {"request byte exhaustion rejects application dispatch", :request_limit},
      {"unavailable cleanup authority preserves a real collected exit", :exit_custody},
      {"recovery publication outlives a renewed worker lease", :renewal},
      {"recovery task death cancels publication and retries without execution", :task_death},
      {"lease loss stops publication and preserves capacity", :lease_loss}
    ]

    cases =
      for {title, scenario} <- scenarios do
        quote do
          test unquote("node authority: " <> title), context do
            Contract.run(unquote(scenario), context)
          end
        end
      end

    quote do
      use ExUnit.Case, unquote(options)
      @moduletag capture_log: true
      setup_all do
        Contract.tls()
      end

      setup context do
        {adapter, store} = __MODULE__.contract_store()
        Contract.setup(context, adapter, store)
      end

      unquote_splicing(cases)
    end
  end

  def tls do
    directory = temporary("tls")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    %{tls: SmolBox.TestTLS.create(directory)}
  end

  def setup(context, adapter, store) do
    {kube, peer} = Peer.start(context.tls, pod_uid: &NodeAuthorityPeer.uid/0)
    root = temporary("runtime")
    controller = Path.join(root, "controller")
    File.mkdir_p!(controller)
    executable = Path.join(controller, "controller-peer")
    File.cp!(@executable, executable)
    File.chmod!(executable, 0o700)

    {:ok, guard} =
      LabController.new(directory: "/private/fixture-controller", python_executable: executable)

    {kube, node, authority} = NodeAuthorityPeer.start(kube, peer, Path.join(root, "node"))
    artifacts = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{} end}, id: make_ref())
    spy = NodeAuthorityStore.new(adapter, store)

    ExUnit.Callbacks.on_exit(fn ->
      if runtime = Process.whereis(context.module), do: Supervisor.stop(runtime, :normal, 5000)
      closed = root <> "-closed"
      File.rename!(root, closed)
      File.rm_rf!(closed)
    end)

    %{
      kube: %{kube | controller_guard: guard},
      peer: peer,
      node: node,
      authority: authority,
      root: root,
      controller: controller,
      adapter: adapter,
      store: store,
      spy: spy,
      artifacts: artifacts
    }
  end

  def run(:binary_io, c) do
    input = <<0, 255, 128, 10>>
    output = <<254, 0, 127, 255>>
    Agent.update(c.artifacts, &Map.put(&1, {"unit", "input"}, input))
    files = ExUnit.Callbacks.start_supervised!({Agent, fn -> %{} end}, id: make_ref())

    frames = fn header, data ->
      case header["operation"] do
        "upload" ->
          Agent.update(files, &Map.put(&1, header["path"], data))
          ExecPeer.file_frames("upload", header["path"], data)

        "download" ->
          bytes = Agent.get(files, &Map.fetch!(&1, header["path"]))
          ExecPeer.file_frames("download", header["path"], bytes)

        "exec" ->
          assert Agent.get(files, & &1["/workspace/input"]) == input
          Agent.update(files, &Map.put(&1, "/workspace/output", output))
          [{:binary, <<1, "SBK1", 0::32, input::binary>>}, ExecPeer.status(7)]
      end
    end

    overrides = [
      inputs: [
        %{
          "source" => "input",
          "path" => "/workspace/input",
          "size" => byte_size(input),
          "sha256" => Files.sha256(input),
          "mode" => "runtime_default"
        }
      ],
      outputs: [%{"destination" => "output", "path" => "/workspace/output", "max_bytes" => 32}]
    ]

    finished = execute(c, frames, overrides)
    assert finished.state == :completed and finished.collection == :complete
    assert %{exit_code: 7, stdout: ^input, stderr: ""} = finished.result

    assert Agent.get(c.artifacts, &Map.fetch!(&1, {Execution.key(finished), "output"})) ==
             {output, Files.sha256(output)}

    assert [%{"size" => 4, "sha256" => digest}] = finished.artifacts
    assert digest == Files.sha256(output)
    assert exec_operations() == ["upload", "download", "exec", "download"]
    assert_release(c, finished)
  end

  def run(scenario, c)
      when scenario in [:tiny_output, :small_output, :exact_output, :excess_output] do
    cap = if scenario == :tiny_output, do: 1, else: 4096
    c = output_cap(c, cap)

    {stdout, stderr, exit} =
      case scenario do
        :exact_output -> {:binary.copy(<<255>>, 2048), :binary.copy(<<254>>, 2048), 7}
        :excess_output -> {:binary.copy(<<255>>, 4096), <<254>>, 0}
        _ -> {"", "", 0}
      end

    finished =
      execute(c, [
        {:binary, <<1, "SBK1", 0::32, stdout::binary>>},
        {:binary, <<2, stderr::binary>>},
        ExecPeer.status(exit)
      ])

    if scenario == :excess_output do
      assert finished.state == :unknown and finished.result == nil
      assert finished.last_error.category == :output_limit
    else
      assert finished.state == :completed and finished.last_error == nil

      assert %{exit_code: ^exit, stdout: ^stdout, stderr: ^stderr, truncated: false} =
               finished.result
    end

    assert exec_operations() == ["exec"]
    assert_release(c, finished)
  end

  def run(:lost_create, c) do
    Peer.change(c.peer, &%{&1 | mode: :lost_create, ready: true})
    runtime = start(c)
    ready(runtime)
    {:ok, key} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)
    finished = finished(c, key)
    assert finished.result == nil
    assert exec_operations() == []
    assert count(c, "POST") == 1
    assert_release(c, finished)
  end

  def run(:lost_status, c) do
    finished = execute(c, [{:binary, <<1, "SBK1", 0::32, "partial">>}])
    assert finished.state == :unknown and finished.result == nil
    assert exec_operations() == ["exec"]
    assert_release(c, finished)
  end

  def run(:cancel_dispatched, c) do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, [], mode: :hold)
    runtime = start(c)
    ready(runtime)
    {:ok, {scope, id} = key} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)
    assert_receive {:exec_request, _, %{"operation" => "exec"}}, 5000
    assert {:ok, _} = SmolBox.cancel(runtime, scope, id)
    finished = finished(c, key)
    assert finished.state == :unknown and finished.result == nil
    assert finished.evidence == :termination_confirmed
    assert count(c, "POST") == 1
    assert_release(c, finished)
  end

  def run(:cancel_queued, c) do
    runtime = start(c)
    ready(runtime)
    assert :ok = SmolBox.drain_worker(runtime, c.kube.id)
    {:ok, {scope, id} = key} = SmolBox.submit(runtime, Fixture.execution(c.kube).spec)
    assert {:ok, %{state: :accepted, reservation: nil}} = fetch(c, key)
    assert {:ok, _} = SmolBox.cancel(runtime, scope, id)
    record = finished(c, key)
    assert record.state == :cancelled and record.backend_assignment == nil
    assert exec_operations() == []
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
    assert {:ok, %{slots: 0}} = call(c, :usage, [c.kube.id])
  end

  def run(:occupied, c) do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, [], mode: :hold)
    runtime = start(c)
    ready(runtime)
    spec = Fixture.execution(c.kube).spec
    {:ok, first} = SmolBox.submit(runtime, %{spec | id: "queue-first"})
    assert_receive {:exec_request, _, %{"operation" => "exec"}}, 5000
    {:ok, second} = SmolBox.submit(runtime, %{spec | id: "queue-second"})

    eventually(fn ->
      {:ok, queued} = fetch(c, second)
      queued.state != :accepted or queued.next_due_at_ms > queued.accepted_at_ms
    end)

    assert {:ok, %{state: :accepted, reservation: nil, last_error: nil}} = fetch(c, second)
    assert count(c, "POST") == 1
    ExecPeer.install(c.peer, %{machine_name: :any}, success())
    assert {:ok, _} = SmolBox.cancel(runtime, elem(first, 0), elem(first, 1))
    first = finished(c, first)
    second = finished(c, second)
    assert second.state == :completed and second.result.exit_code == 0
    refute first.backend_receipt.pod_uid == second.backend_receipt.pod_uid
    assert count(c, "POST") == 2
    assert_release(c, second)
  end

  def run(mode, c) when mode in [:changed_epoch, :changed_manifest, :missing, :corrupt] do
    record = seed(c, :ready)
    {:ok, _} = call(c, :cancel, [Execution.key(record), System.system_time(:millisecond)])
    Peer.change(c.peer, &%{&1 | pod: nil})
    NodeAuthorityPeer.mode(c.node, mode)
    runtime = start(c, true, ["owner-previous"])
    eventually(fn -> NodeAuthorityPeer.requests(c.node) != [] end)
    Process.sleep(150)
    assert {:ok, %{slots: 1}} = call(c, :usage, [c.kube.id])

    assert {:ok, %{reservation: reservation, backend_cleanup: nil}} =
             fetch(c, Execution.key(record))

    assert reservation != nil
    assert worker_status(runtime) == :unavailable
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
    NodeAuthorityPeer.mode(c.node, :normal)
    finished = finished(c, Execution.key(record))
    assert finished.state == :cancelled and finished.result == nil
    assert exec_operations() == []
    assert_release(c, finished)
  end

  def run(:old_lab, c) do
    epoch = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    record = seed(c, :ready, epoch)
    {:ok, _} = call(c, :cancel, [Execution.key(record), System.system_time(:millisecond)])
    Peer.change(c.peer, &%{&1 | pod: nil})
    runtime = start(c, true, ["owner-previous"])
    eventually(fn -> NodeAuthorityStore.events(c.spy).pages != [] end)
    Process.sleep(200)
    assert worker_status(runtime) == :unavailable
    assert {:ok, %{slots: 1}} = call(c, :usage, [c.kube.id])

    assert {:ok, %{backend_receipt: receipt, backend_cleanup: nil}} =
             fetch(c, Execution.key(record))

    assert receipt.observation.observer_epoch == epoch
    assert exec_operations() == []
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
  end

  def run(scenario, c) when scenario in [:cancel_ready, :expired_ready, :pages] do
    c =
      if scenario == :expired_ready,
        do: Map.put(c, :seed_age, hd(c.kube.profiles).preparation_ms + 2000),
        else: c

    record = seed(c, :ready)

    cancel = fn ->
      {:ok, _} = call(c, :cancel, [Execution.key(record), System.system_time(:millisecond)])
      Peer.change(c.peer, &%{&1 | pod: nil})
    end

    if scenario == :pages do
      marker = Fixture.execution(c.kube, id: "z-paging-marker")
      {:ok, _, :inserted} = call(c, :accept, [marker, 10])
      {:ok, _} = call(c, :cancel, [Execution.key(marker), System.system_time(:millisecond)])
      caller = self()

      NodeAuthorityStore.change(c.spy, fn events ->
        %{
          events
          | scan:
              {:after_cursor,
               fn ->
                 cancel.()
                 send(caller, :between_pages)
               end}
        }
      end)
    else
      if scenario == :expired_ready,
        do: Peer.change(c.peer, &%{&1 | pod: nil}),
        else: cancel.()
    end

    runtime = start(c, true, ["owner-previous"])
    if scenario == :pages, do: assert_receive(:between_pages, 5000)
    finished = finished(c, Execution.key(record))
    assert finished.state == if(scenario == :expired_ready, do: :failed, else: :cancelled)
    assert finished.result == nil
    assert exec_operations() == []
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
    assert_release(c, finished)
    ready(runtime)
  end

  def run(:foreign, c) do
    foreign = %{
      "metadata" => %{"name" => "foreign", "uid" => NodeAuthorityPeer.uid()},
      "spec" => %{}
    }

    Peer.change(c.peer, &%{&1 | pod: foreign})
    runtime = start(c)
    eventually(fn -> NodeAuthorityStore.events(c.spy).pages != [] end)
    Process.sleep(200)
    assert worker_status(runtime) == :unavailable
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
    assert Agent.get(c.peer, & &1.pod) == foreign
    Peer.change(c.peer, &%{&1 | pod: nil})
    ready(runtime)
  end

  def run(:replacement, c) do
    record = seed(c, :dispatching)
    original = Agent.get(c.peer, & &1.pod)
    foreign = put_in(original["metadata"]["uid"], NodeAuthorityPeer.uid())
    Peer.change(c.peer, &%{&1 | pod: foreign})
    runtime = start(c, true, ["owner-previous"])

    eventually(fn ->
      {:ok, current} = fetch(c, Execution.key(record))
      current.cleanup_attempts > 0
    end)

    assert Agent.get(c.peer, & &1.pod) == foreign
    assert worker_status(runtime) == :unavailable
    assert {:ok, %{slots: 1}} = call(c, :usage, [c.kube.id])
    assert count(c, "DELETE") == 0 and count(c, "POST") == 0
    assert exec_operations() == []
    Peer.change(c.peer, &%{&1 | pod: original})
    finished = finished(c, Execution.key(record))
    assert finished.state == :unknown and finished.result == nil
    assert_release(c, finished)
  end

  def run(:request_limit, c) do
    c = %{c | kube: %{c.kube | budget: %{c.kube.budget | max_request_bytes: 100_000}}}
    env = Enum.map(1..16, &{"DATA_#{&1}", String.duplicate("x", 8192)})
    {:ok, command} = Command.new(["python3", "-c", "pass"], env: env)
    {:ok, payload} = GuestHelper.encode(command)
    assert byte_size(payload) > c.kube.budget.max_request_bytes
    finished = execute(c, success(), command: command)

    assert finished.state == :unknown
    assert finished.result == nil
    assert finished.last_error.category == :unsupported_capability
    assert exec_operations() == []
    refute Enum.any?(Peer.requests(c.peer), &String.ends_with?(&1.path, "/exec"))
    assert_release(c, finished)
  end

  def run(:exit_custody, c) do
    bytes = <<0, 255, 128>>
    output = %{"destination" => "output", "path" => "/workspace/output", "max_bytes" => 1024}

    frames = fn header, _ ->
      if header["operation"] == "exec",
        do: [{:binary, <<1, "SBK1", 0::32>>}, ExecPeer.status(7)],
        else: ExecPeer.file_frames(header["operation"], header["path"], bytes)
    end

    c = Map.put(c, :artifact_store, {GatedArtifacts, %{store: c.artifacts, owner: self()}})
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, frames)
    runtime = start(c)
    ready(runtime)
    {:ok, key} = SmolBox.submit(runtime, Fixture.execution(c.kube, outputs: [output]).spec)
    assert_receive {:publishing, publisher}, 5000
    NodeAuthorityPeer.mode(c.node, :proof_unavailable)
    send(publisher, :publish)

    eventually(fn ->
      {:ok, current} = fetch(c, key)
      current.collection == :complete and current.cleanup_attempts > 0
    end)

    assert {:ok, %{result: %{exit_code: 7}, backend_cleanup: nil, reservation: reservation}} =
             fetch(c, key)

    assert reservation != nil
    assert {:ok, %{slots: 1}} = call(c, :usage, [c.kube.id])
    NodeAuthorityPeer.mode(c.node, :normal)
    finished = finished(c, key)
    assert finished.state == :completed and finished.result.exit_code == 7
    assert exec_operations() == ["exec", "download"]
    assert count(c, "POST") == 1
    assert_release(c, finished)
  end

  def run(scenario, c) when scenario in [:renewal, :task_death, :lease_loss] do
    c = if scenario == :lease_loss, do: Map.put(c, :lease_ms, 1000), else: c
    output = %{"destination" => "output", "path" => "/workspace/output", "max_bytes" => 1024}
    c = Map.put(c, :spec_overrides, outputs: [output])
    record = seed(c, :dispatching)

    {:ok, record} =
      call(c, :write, [
        Execution.key(record),
        Session.guard(record),
        [
          state: :collecting,
          evidence: :exited,
          result: %Result{exit_code: 7, stdout: "", stderr: "", encoding: :bytes}
        ],
        record.updated_at_ms + 1
      ])

    bytes = <<0, 255, 128>>

    ExecPeer.install(c.peer, record, fn header, _ ->
      ExecPeer.file_frames(header["operation"], header["path"], bytes)
    end)

    c = Map.put(c, :artifact_store, {GatedArtifacts, %{store: c.artifacts, owner: self()}})
    runtime = start(c, true, ["owner-previous"])
    assert_receive {:publishing, publisher}, 5000

    publisher = publication(scenario, c, runtime, record, publisher)

    assert worker_status(runtime) == :unavailable
    assert count(c, "POST") == 0 and count(c, "DELETE") == 0
    send(publisher, :publish)
    finished = finished(c, Execution.key(record))
    assert finished.state == :completed and finished.collection == :complete

    assert finished.result == record.result and
             finished.deadlines.collection == record.deadlines.collection

    assert Agent.get(c.artifacts, &Map.fetch!(&1, {Execution.key(record), "output"})) ==
             {bytes, Files.sha256(bytes)}

    operations = exec_operations()
    assert Enum.all?(operations, &(&1 == "download"))
    assert length(operations) == if(scenario == :renewal, do: 1, else: 2)
    assert_release(c, finished)
    ready(runtime)
  end

  defp publication(scenario, c, runtime, record, publisher) do
    case scenario do
      :renewal ->
        initial = hd(NodeAuthorityStore.events(c.spy).leases)

        {:ok, queued} =
          SmolBox.submit(runtime, %{record.spec | id: "queued-during-recovery", outputs: []})

        Process.sleep(5250)
        assert Process.alive?(publisher)
        renewed = hd(NodeAuthorityStore.events(c.spy).leases)

        assert renewed.until_ms > initial.until_ms and
                 renewed.until_ms > System.system_time(:millisecond)

        assert {:ok, %{state: :accepted, reservation: nil}} = fetch(c, queued)
        {:ok, _} = SmolBox.cancel(runtime, elem(queued, 0), elem(queued, 1))
        publisher

      :task_death ->
        monitor = Process.monitor(publisher)
        {holder, _} = :sys.get_state(Runtime.coordinator(runtime)).native_holders[c.kube.id]
        Process.exit(holder, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 2000
        assert_receive {:publishing, replacement}, 5000
        assert replacement != publisher
        replacement

      :lease_loss ->
        monitor = Process.monitor(publisher)
        NodeAuthorityStore.change(c.spy, &%{&1 | deny_lease: true})
        assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 3000
        assert Agent.get(c.artifacts, &map_size/1) == 0
        assert {:ok, %{slots: 1}} = call(c, :usage, [c.kube.id])
        NodeAuthorityStore.change(c.spy, &%{&1 | deny_lease: false})
        assert_receive {:publishing, replacement}, 5000
        replacement
    end
  end

  defp execute(c, frames, overrides \\ []) do
    Peer.change(c.peer, &%{&1 | ready: true})
    ExecPeer.install(c.peer, %{machine_name: :any}, frames)
    runtime = start(c)
    ready(runtime)
    {:ok, key} = SmolBox.submit(runtime, Fixture.execution(c.kube, overrides).spec)
    finished = finished(c, key)
    assert count(c, "POST") == 1
    finished
  end

  defp start(c, enrolled \\ false, owners \\ []) do
    File.write!(
      Path.join(c.controller, "response.json"),
      Jason.encode!(%{
        mode: "controller",
        controller: %{enrolled: enrolled, known_owners: owners}
      })
    )

    ExUnit.Callbacks.start_supervised!(
      {SmolBox,
       [
         name: c.module,
         namespace: "kubefiles",
         mode: :ephemeral,
         store: {NodeAuthorityStore, c.spy},
         artifact_store: Map.get(c, :artifact_store, {TestArtifacts, c.artifacts}),
         workers: [c.kube],
         fingerprint_key: String.duplicate("k", 32),
         poll_ms: 20,
         lease_ms: Map.get(c, :lease_ms, 5000)
       ]}
    )
  end

  defp seed(c, state, epoch \\ nil) do
    now = System.system_time(:millisecond) - Map.get(c, :seed_age, 2000)
    record = Fixture.execution(c.kube, Map.get(c, :spec_overrides, []), now)
    {:ok, assignment} = Assignment.new(c.kube, record, "kube-seeded")
    {:ok, _} = call(c, :bind_backend, [c.kube.id, Config.binding(c.kube)])
    {:ok, _} = call(c, :claim_worker, [c.kube.id, "owner-previous", now, 1000])
    {:ok, _, :inserted} = call(c, :accept, [record, 10])
    {:ok, record} = call(c, :claim, [Execution.key(record), "owner-previous", now, 1000])

    {:ok, record} =
      call(c, :reserve, [
        Execution.key(record),
        Session.guard(record),
        {c.kube.id, assignment.pod_name, c.kube.capacity, assignment},
        now
      ])

    uid = NodeAuthorityPeer.uid()
    {:ok, created} = Receipt.created(assignment, uid)

    observation =
      NodeAuthorityPeer.observation(
        assignment.binding,
        uid,
        epoch || c.authority.authority_generation,
        now
      )

    {:ok, receipt} =
      Receipt.ready(
        created,
        "containerd://" <> Fixture.digest(),
        assignment.source["reference"],
        observation
      )

    {:ok, record} =
      call(c, :write, [
        Execution.key(record),
        Session.guard(record),
        [backend_create_state: :dispatched, backend_receipt: created],
        now
      ])

    machine = Fixture.machine(receipt, record.spec.profile)

    {:ok, record} =
      call(c, :write, [
        Execution.key(record),
        Session.guard(record),
        [backend_receipt: receipt, created_machine: machine, state: :ready],
        now
      ])

    record =
      if state == :dispatching do
        {:ok, next} =
          call(c, :write, [
            Execution.key(record),
            Session.guard(record),
            [state: :dispatching, evidence: :dispatch_uncertain],
            now
          ])

        next
      else
        record
      end

    pod =
      Assignment.manifest(assignment) |> Peer.effective(true) |> put_in(["metadata", "uid"], uid)

    Peer.change(c.peer, &%{&1 | pod: pod})
    record
  end

  defp output_cap(c, cap) do
    profile = %{hd(c.kube.profiles) | max_output_bytes: cap}

    Peer.change(
      c.peer,
      &put_in(&1.objects.node["metadata"]["annotations"], %{
        "fixture.example/node-metadata" => String.duplicate("n", 4096)
      })
    )

    %{c | kube: %{c.kube | profiles: [profile]}}
  end

  defp assert_release(c, record) do
    assert record.cleanup == :complete and record.reservation == nil
    assert record.backend_cleanup.version == 3
    assert record.backend_cleanup.receipt == record.backend_receipt
    assert record.backend_cleanup.observer_epoch == c.authority.authority_generation
    assert {:ok, %{slots: 0}} = call(c, :usage, [c.kube.id])

    assert {:ok, <<"smolbox-record-v54\0", _::binary>> = encoded} = Codec.encode(record)

    assert {:ok, ^record} = Codec.decode(encoded)
    refute encoded =~ c.authority.identity_file
    refute encoded =~ c.authority.known_hosts_file
    refute encoded =~ c.authority.ssh_executable

    assert Enum.any?(NodeAuthorityStore.events(c.spy).releases, fn {before, {:ok, after_release}} ->
             before.reservation != nil and before.cleanup == :complete and
               before.backend_cleanup == record.backend_cleanup and
               after_release.reservation == nil
           end)

    uids =
      Enum.map(NodeAuthorityStore.events(c.spy).releases, fn {saved, _} ->
        saved.backend_receipt.pod_uid
      end)

    for request <- Peer.requests(c.peer), request.method == "DELETE" do
      assert request.body["preconditions"]["uid"] in uids
    end

    requests = NodeAuthorityPeer.requests(c.node)
    assert Enum.any?(requests, &(&1["action"] == "cleanup"))
    refute Jason.encode!(requests) =~ "private-command-value"
    refute Jason.encode!(requests) =~ "private-env-value"
  end

  defp finished(c, key) do
    eventually(fn -> match?({:ok, %{cleanup: :complete, reservation: nil}}, fetch(c, key)) end)
    {:ok, record} = fetch(c, key)
    record
  end

  defp exec_operations(acc \\ []) do
    receive do
      {:exec_request, _, header} -> exec_operations([header["operation"] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp temporary(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-authority-#{suffix}-" <> Base.encode16(:crypto.strong_rand_bytes(9))
      )

    File.mkdir_p!(path)
    path
  end

  defp worker_status(runtime) do
    {:ok, reports} = GenServer.call(Runtime.coordinator(runtime), :workers)
    hd(reports).status
  end

  defp ready(runtime), do: eventually(fn -> worker_status(runtime) == :ready end)
  defp success, do: [{:binary, <<1, "SBK1", 0::32>>}, ExecPeer.status(0)]
  defp fetch(c, key), do: call(c, :fetch, [key])
  defp count(c, method), do: Enum.count(Peer.requests(c.peer), &(&1.method == method))
  defp call(c, operation, args), do: apply(c.adapter, operation, [c.store | args])
  defp eventually(callback, attempts \\ 500)
  defp eventually(_, 0), do: flunk("node authority runtime condition not reached")

  defp eventually(callback, attempts) do
    if callback.(),
      do: :ok,
      else:
        (
          Process.sleep(30)
          eventually(callback, attempts - 1)
        )
  end
end
