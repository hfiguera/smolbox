defmodule SmolBox.EmbeddedBackendTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.{Assignment, Embedded, HTTP}
  alias SmolBox.Embedded.{Config, Port}
  alias SmolBox.Runtime.Session
  alias SmolBox.Store.{Contract, Memory}

  alias SmolBox.{
    Backend,
    Client,
    Command,
    Error,
    ExecutionSpec,
    Files,
    MachineSpec,
    ManagedMachine,
    ManagedMachineSpec,
    Result,
    Worker
  }

  alias SmolBox.Test.EmbeddedPackage, as: Package

  test "capture qualification remains unavailable on currently approved native packages",
       context do
    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.qualify_capture(context.reference, true)

    refute Embedded.supports_operation?(context.reference.context, :qualify_capture)
    refute HTTP.supports_operation?(nil, :qualify_capture)

    assert {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.cleanup_capture(context.reference, nil, true)

    refute Embedded.supports_operation?(context.reference.context, :cleanup_capture)
    refute HTTP.supports_operation?(nil, :cleanup_capture)
  end

  test "export controls and cached approval lookup remain gated on current packages", context do
    for operation <- [:qualify_export, :inspect_export, :cleanup_export, :export_machine],
        do: refute(Embedded.supports_operation?(context.reference.context, operation))

    assert {:error, %{evidence: :not_dispatched}} = Backend.qualify_export(context.reference)
    assert {:error, %{evidence: :not_dispatched}} = Backend.inspect_export(context.reference)

    assert {:error, %{evidence: :not_dispatched}} =
             Backend.cleanup_export(context.reference, nil, true)

    {:ok, health} = Port.health(context.owner)
    before = Package.received(context.config)
    assert {:error, _} = Port.export_approval(context.owner, "unapproved", health.epoch, 1000)
    assert Package.received(context.config) == before
  end

  setup do
    config = Package.create(backend: true)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    owner = start_supervised!(Supervisor.child_spec({Port, config}, restart: :temporary))
    wait(owner)
    :ok = Port.activate(owner, Config.domain_binding(config))
    store = start_supervised!(Memory)

    {:ok, _} =
      Memory.bind_backend(
        store,
        config.id,
        struct!(SmolBox.Backend.Binding, Config.domain_binding(config))
      )

    {:ok, _} = Memory.claim_worker(store, config.id, "owner", 1000, 10_000)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native",
        id: "vm",
        profile: hd(config.profiles),
        artifact: config.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)
    {:ok, _} = Memory.machine(store, :accept, [record, 10])

    {:ok, claimed} =
      Memory.machine(store, :claim, [ManagedMachine.key(record), "owner", 1000, 10_000])

    {:ok, assignment} = Assignment.new(config, spec, "fixture-vm")

    {:ok, reserved} =
      Memory.machine(store, :reserve, [
        ManagedMachine.key(record),
        Contract.guard(claimed),
        {config.id, "fixture-vm", config.capacity, assignment},
        1000
      ])

    {:ok, reference} = Embedded.reference(config, owner)
    %{config: config, owner: owner, store: store, record: reserved, reference: reference}
  end

  defp wait(owner, count \\ 200) do
    case Port.health(owner) do
      {:ok, %{status: :reconciling}} ->
        :ok

      _other when count > 0 ->
        Process.sleep(10)
        wait(owner, count - 1)

      _other ->
        flunk("native fixture owner did not become reconciling")
    end
  end

  defp running(context) do
    record = context.record

    {:ok, spec} =
      MachineSpec.new(record.machine_name, record.backend_assignment.creation["artifact"]["path"])

    assert {:ok, created} = Backend.create(Backend.assigned(context.reference, record), spec)

    assert {:ok, saved} =
             Memory.machine(context.store, :write, [
               ManagedMachine.key(record),
               Contract.guard(record),
               [
                 state: :created,
                 operation: nil,
                 phase: nil,
                 created_machine: created,
                 observed_machine: created
               ],
               1100
             ])

    assert {:ok, started} =
             Backend.start(Backend.assigned(context.reference, saved), saved.machine_name)

    assert {:ok, running} =
             Memory.machine(context.store, :write, [
               ManagedMachine.key(record),
               Contract.guard(saved),
               [state: :running, observed_machine: started],
               1200
             ])

    {running, Backend.assigned(context.reference, running)}
  end

  test "saved creation intent and receipt drive lifecycle without invented timestamps", context do
    {record, reference} = running(context)
    assert record.created_machine.created_at == nil
    before = Package.received(context.config)

    assert {:error, %Error{category: :unsupported_capability}} =
             Backend.inspect_creation(reference)

    assert Package.received(context.config) == before

    assert {:ok, %{state: :running, backend_identity: %{pid_identity: [4242, 123_456]}}} =
             Backend.inspect_machine(reference, record.machine_name)

    assert {:ok, %{state: :stopped, backend_identity: %{pid_identity: nil}}} =
             Backend.stop(reference, record.machine_name)

    assert :ok = Backend.delete(reference, record.machine_name)

    assert {:error, %Error{category: :not_found}} =
             Backend.inspect_machine(reference, record.machine_name)

    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.config.id)
  end

  test "intent inspection never adopts matching creation material", context do
    reference = Backend.assigned(context.reference, context.record)
    budget = %{reference.budget | timeout_ms: 30_000}
    {:ok, %{epoch: epoch}} = Port.health(context.owner)
    assert :ok = Port.quiesce(context.owner, epoch)
    before = Package.received(context.config)

    query = %{
      "operation" => "inspect_creation",
      "create" => context.record.backend_assignment.creation
    }

    unapproved = put_in(query, ["create", "artifact", "sha256"], String.duplicate("0", 64))

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Port.submit(context.owner, unapproved, budget, self(), epoch)

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Port.submit(
               context.owner,
               query,
               budget,
               self(),
               String.duplicate("0", 32)
             )

    assert Package.received(context.config) == before
    assert {:ok, :absent} = Backend.inspect_creation(reference)
    assert :ok = Port.activate(context.owner, Config.domain_binding(context.config), epoch)

    assert {:ok, spec} =
             MachineSpec.new(
               context.record.machine_name,
               context.record.backend_assignment.creation["artifact"]["path"]
             )

    assert {:ok, _lost_reply} = Backend.create(reference, spec)
    assert {:error, %Error{category: :identity_conflict}} = Backend.inspect_creation(reference)

    assert {:ok, %{created_machine: nil, reservation: reservation}} =
             Memory.machine(context.store, :fetch, [ManagedMachine.key(context.record)])

    assert reservation == context.record.reservation
  end

  test "foreground commands preserve byte-exact binary output and observed nonzero Exit",
       context do
    {record, reference} = running(context)

    {:ok, command} =
      Command.new(["echo"], timeout_secs: 1, env: [{"TEST", "value"}], user: "65534")

    assert {:ok,
            %Result{
              exit_code: 7,
              stdout: <<"out", 0, 255>>,
              stderr: <<"err", 0, 254>>,
              encoding: :bytes
            }} = Backend.exec(reference, record.machine_name, command)

    request =
      Package.received(context.config) |> Enum.filter(&(&1["type"] == "request")) |> List.last()

    assert request["operation"]["command"]["env"] == %{"TEST" => "value"}
    assert request["operation"]["command"]["user"] == "65534"
    refute inspect(reference) =~ record.backend_assignment.creation["owner_token"]
  end

  test "negative native completion retains actual Exit and partial byte output", context do
    {record, reference} = running(context)
    {:ok, command} = Command.new(["exit_error"], timeout_secs: 1)

    assert {:error, %Error{evidence: :exited, exit_code: 7},
            %Result{
              exit_code: 7,
              stdout: <<"out", 0, 255>>,
              stderr: <<"err", 0, 254>>,
              truncated: true
            }} = Backend.exec(reference, record.machine_name, command)
  end

  test "upload/download uses bounded chunks and atomic native completion including empty files",
       context do
    {record, reference} = running(context)
    bytes = :binary.copy(<<0, 255, 254, 1>>, 40_000)

    assert :ok =
             Backend.upload(
               reference,
               record.machine_name,
               "/workspace/data",
               bytes,
               Files.sha256(bytes)
             )

    assert {:ok, ^bytes} =
             Backend.download(reference, record.machine_name, "/workspace/data", byte_size(bytes))

    assert :ok =
             Backend.upload(
               reference,
               record.machine_name,
               "/workspace/empty",
               <<>>,
               Files.sha256(<<>>)
             )

    assert {:ok, <<>>} = Backend.download(reference, record.machine_name, "/workspace/empty", 1)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Backend.upload(
               reference,
               record.machine_name,
               "/workspace/data",
               bytes,
               String.duplicate("0", 64)
             )
  end

  test "ownership, domain and package mismatches fail before any helper request", context do
    count = length(Package.received(context.config))
    wrong = %{context.config | domain_generation: String.duplicate("a", 32)}

    record = context.record
    changed = put_in(record.backend_assignment.binding.generation, wrong.domain_generation)

    {:ok, reference} = Embedded.reference(wrong, context.owner)

    {:ok, spec} =
      MachineSpec.new(
        changed.machine_name,
        changed.backend_assignment.creation["artifact"]["path"]
      )

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Backend.create(Backend.assigned(reference, changed), spec)

    assert length(Package.received(context.config)) == count

    assert {:error, %Error{category: :identity_conflict}} =
             Session.safe(fn ->
               Backend.assigned(context.reference, %{context.record | backend_assignment: nil})
             end)

    wrong_package = %{context.config | package_manifest_sha256: String.duplicate("0", 64)}
    {:ok, reference} = Embedded.reference(wrong_package, context.owner)

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Backend.create(Backend.assigned(reference, context.record), spec)

    assert length(Package.received(context.config)) == count

    {:ok, worker} =
      Worker.new(context.config.id, "http://127.0.0.1:9", allow_insecure_loopback: true)

    {:ok, client} = Client.new(worker)

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Session.safe(fn -> Backend.assigned(HTTP.reference(client), context.record) end)

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.inspect_creation(HTTP.reference(client))
  end

  test "unsupported commands and optional features fail without helper invocation", context do
    {record, reference} = running(context)
    count = length(Package.received(context.config))
    {:ok, command} = Command.new(["echo"], stdin: "input")

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.exec(reference, record.machine_name, command)

    assert {:error, %Error{category: :unsupported_capability}} =
             Backend.logs(reference, record.machine_name)

    assert {:error, %Error{category: :validation}} =
             Backend.download(reference, record.machine_name, "/etc/passwd", 100)

    assert length(Package.received(context.config)) == count
    env = for index <- 1..32, do: {"ENV_#{index}", String.duplicate("x", 8192)}
    {:ok, command} = Command.new(["echo"], env: env)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: record.scope,
        id: "too-large",
        artifact: record.spec.artifact,
        profile: record.spec.profile,
        command: command
      )

    assert {:error, %Error{category: :unsupported_capability}} =
             Assignment.new(context.config, spec, "large-env")
  end

  test "a deadline cancels only this request and does not fabricate an Exit", context do
    {record, reference} = running(context)
    reference = Backend.bounded(reference, timeout_ms: 30)
    {:ok, command} = Command.new(["hold"], timeout_secs: 1)

    assert {:error, %Error{category: :expired, exit_code: nil}} =
             Backend.exec(reference, record.machine_name, command)

    assert {:ok, %{state: :running}} =
             Backend.inspect_machine(
               context.reference |> Backend.assigned(record),
               record.machine_name
             )

    assert {:ok, %{slots: 1}} = Memory.usage(context.store, context.config.id)
  end

  @tag :deferred_crash
  test "losing the owner resolves once conservatively through the monitored original PID",
       context do
    {record, reference} = running(context)
    {:ok, command} = Command.new(["hold"], timeout_secs: 1)
    task = Task.async(fn -> Backend.exec(reference, record.machine_name, command) end)

    await_message(
      context.config,
      &(&1["type"] == "request" and
          &1["operation"]["operation"] == "exec")
    )

    Process.unlink(context.owner)
    Process.exit(context.owner, :kill)

    assert {:error, %Error{exit_code: nil, evidence: :dispatch_uncertain}} =
             Task.await(task, 2000)
  end

  test "inspection requires a saved receipt and never infers ownership from the intent",
       context do
    count = length(Package.received(context.config))

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Backend.inspect_machine(
               Backend.assigned(context.reference, context.record),
               context.record.machine_name
             )

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Backend.inspect_machine(context.reference, context.record.machine_name)

    assert length(Package.received(context.config)) == count
  end

  @tag :deferred_crash
  test "caller death cancels its accepted command while the owner remains usable", context do
    {record, reference} = running(context)
    {:ok, command} = Command.new(["hold"], timeout_secs: 1)
    caller = spawn(fn -> Backend.exec(reference, record.machine_name, command) end)

    request =
      await_message(
        context.config,
        &(&1["type"] == "request" and
            &1["operation"]["operation"] == "exec")
      )

    Process.exit(caller, :kill)
    await_message(context.config, &(&1["type"] == "cancel" and &1["id"] == request["id"]))
    assert {:ok, %{state: :running}} = Backend.inspect_machine(reference, record.machine_name)
  end

  test "a blocked callback has a finite deadline and releases its observer", context do
    {record, reference} = running(context)
    reference = Backend.bounded(reference, timeout_ms: 30)
    {:ok, command} = Command.new(["hold_output"], timeout_secs: 1)
    callback = fn _event -> receive do: (:never -> :ok) end

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain, exit_code: nil}} =
             Backend.exec_stream(reference, record.machine_name, command, on_event: callback)

    await_message(context.config, &(&1["type"] == "cancel"))

    assert {:ok, %{state: :running}} =
             Backend.inspect_machine(
               Backend.assigned(context.reference, record),
               record.machine_name
             )
  end

  test "an unresponsive health owner is bounded without marking a request dispatched", context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
          _message -> receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> send(owner, :stop) end)
    {:ok, reference} = Embedded.reference(context.config, owner)
    reference = reference |> Backend.assigned(context.record) |> Backend.bounded(timeout_ms: 20)

    {:ok, spec} =
      MachineSpec.new(
        context.record.machine_name,
        context.record.backend_assignment.creation["artifact"]["path"]
      )

    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} =
             Backend.create(reference, spec)
  end

  defp await_message(config, predicate, remaining \\ 200) do
    case Enum.find(Package.received(config), predicate) do
      nil when remaining > 0 ->
        Process.sleep(5)
        await_message(config, predicate, remaining - 1)

      nil ->
        flunk("expected helper request was not observed")

      message ->
        message
    end
  end
end
