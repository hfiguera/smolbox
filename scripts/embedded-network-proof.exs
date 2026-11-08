defmodule SmolBox.EmbeddedNetworkProof do
  @moduledoc false
  alias SmolBox.{
    Command,
    ExecutionSpec,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    PortMapping,
    Profile,
    Runtime,
    Workload
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Embedded.Config
  alias SmolBox.Store.{Codec, Memory}
  @scope "native-network"

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          package: :string,
          manifest_sha256: :string,
          fixture: :string,
          sha256: :string,
          domain_json: :string,
          output: :string,
          host_port: :integer,
          inventory_helper: :string,
          without_rust: :boolean,
          namespace_identity: :string,
          startup_workloads: :boolean
        ]
      )

    true = :os.type() == {:unix, :linux}
    true = options[:without_rust]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    {"smolbox-nested\n", 0} = System.cmd("hostname", [])
    {"1000\n", 0} = System.cmd("id", ["-u"])
    {identity, 0} = System.cmd("readlink", ["/proc/self/ns/net"])
    true = String.trim(identity) == Keyword.fetch!(options, :namespace_identity)
    root = Path.expand(Keyword.fetch!(options, :output))
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    :ok = File.mkdir(Path.join(root, "objects"))
    :ok = File.chmod(Path.join(root, "objects"), 0o700)
    tooling = Path.expand(Keyword.fetch!(options, :inventory_helper))
    [] = helper(tooling, "inventory")
    workloads = options[:startup_workloads] == true
    mapped = options[:host_port]

    unless workloads do
      true = helper(tooling, "positive")
      true = mapped in 1024..65_535
      [] = helper(tooling, "listeners", [Integer.to_string(mapped)])
    end

    package = Path.expand(Keyword.fetch!(options, :package))
    manifest_bytes = File.read!(Path.join(package, "package.json"))
    manifest_sha = Base.encode16(:crypto.hash(:sha256, manifest_bytes), case: :lower)
    ^manifest_sha = Keyword.fetch!(options, :manifest_sha256)
    manifest = Jason.decode!(manifest_bytes)
    domain = options |> Keyword.fetch!(:domain_json) |> File.read!() |> Jason.decode!()
    fixture = options |> Keyword.fetch!(:fixture) |> Path.expand()
    {:ok, network} = NetworkPolicy.new(cidrs: ["198.18.0.10/32"])

    policies =
      if workloads, do: [{"offline", :offline}], else: [{"offline", :offline}, {"cidr", network}]

    profiles =
      Enum.map(policies, fn {id, policy} ->
        {:ok, profile} =
          Profile.new("native-" <> id,
            cpus: 1,
            memory_mb: 512,
            storage_gb: 1,
            overlay_gb: 1,
            network: policy,
            max_file_bytes: 65_536,
            preparation_ms: 120_000,
            execution_ms: 30_000
          )

        profile
      end)

    artifact = %{
      "id" => "network-python",
      "path" => fixture,
      "sha256" => Keyword.fetch!(options, :sha256),
      "architecture" => "x86_64",
      "max_bytes" => File.stat!(fixture).size
    }

    {:ok, target} =
      Config.new(
        id: domain["target_id"],
        bridge: :port,
        package_path: package,
        package_manifest_sha256: manifest_sha,
        package_identity: manifest["identity"],
        sdk_identity: get_in(manifest, ["policy", "sdk"]),
        domain_generation: domain["generation"],
        allow_initialize: false,
        platform: :linux,
        architecture: "x86_64",
        profiles: profiles,
        artifacts: [artifact],
        capacity: %{slots: 2, cpus: 2, memory_mb: 1536, disk_gb: 4},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 256}
      )

    {:ok, objects} = Directory.new(Path.join(root, "objects"))
    store = {Memory, Module.concat(__MODULE__, Store)}
    key = :crypto.strong_rand_bytes(32)
    save(root, "private-fingerprint-key", key)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Memory, name: elem(store, 1)},
          {SmolBox,
           name: __MODULE__,
           namespace: "netproof",
           store: store,
           mode: :ephemeral,
           artifact_store: {Directory, objects},
           fingerprint_key: key,
           workers: [target],
           poll_ms: 50,
           lease_ms: 1000}
        ],
        strategy: :one_for_one
      )

    context = %{
      target: target,
      root: root,
      tooling: tooling,
      mapped: mapped,
      artifact: Map.take(artifact, ~w(id sha256 architecture)),
      supervisor: supervisor
    }

    try do
      ready(target.id)

      cases =
        if workloads do
          workload_cases(Map.put(context, :profile, hd(profiles)))
        else
          Enum.map(profiles, &network_case(Map.put(context, :profile, &1)))
        end

      :ok = SmolBox.drain_worker(__MODULE__, target.id)
      {:ok, report} = SmolBox.worker_maintenance(__MODULE__, target.id)
      true = report.records == [] and report.reserved.slots == 0
      :ok = Supervisor.terminate_child(supervisor, {Runtime, __MODULE__})
      [] = helper(tooling, "inventory")

      save(
        root,
        "evidence.json",
        Jason.encode!(%{
          proof: "passed",
          scope: "public-port-package-consumer",
          campaign:
            if(workloads,
              do: "ordinary-public-native-workloads",
              else: "ordinary-public-native-network-mappings"
            ),
          without_rust: true,
          public_native_admission_enabled: true,
          public_memory_port_reservations_qualified: not workloads,
          package_manifest_sha256: manifest_sha,
          identity: manifest["identity"],
          fixture_sha256: artifact["sha256"],
          cases: cases,
          final_reserved_slots: 0,
          owned_deleted: true,
          inventory_restored: true,
          inventory_before: [],
          inventory_after: [],
          workload_startup_qualified: workloads,
          native_postgresql_qualified: false,
          deliberate_process_interruption: false,
          crash_handling_qualified: false
        })
      )

      IO.puts("Public native feature proof passed; reservations and SDK inventory empty")
    after
      try do
        preserve_records(root, store, target.id)
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  defp workload_cases(c) do
    {:ok, inherited} = Workload.new()

    program = """
    import json,os,pathlib,sys
    event={'kind':'override','argv':sys.argv[1:],'cwd':os.getcwd(),'uid':os.geteuid(),
           'inherited':os.environ.get('SMOLBOX_INHERITED'),
           'override':os.environ.get('SMOLBOX_OVERRIDE'),'extra':os.environ.get('SMOLBOX_EXTRA')}
    with pathlib.Path('/workspace/startup-events.jsonl').open('a') as stream:
        stream.write(json.dumps(event)+'\\n')
    sys.exit(7)
    """

    {:ok, override} =
      Workload.new(
        entrypoint: ["python"],
        cmd: ["-c", program, "replacement literal; text"],
        env: [{"SMOLBOX_OVERRIDE", "override"}, {"SMOLBOX_EXTRA", "explicit"}],
        workdir: "/"
      )

    {:ok, missing} = Workload.new(entrypoint: ["/missing-startup-program"], cmd: [])

    Enum.map(
      [{"neutral", nil}, {"inherited", inherited}, {"override", override}, {"missing", missing}],
      fn {id, workload} -> workload_case(c, id, workload, inherited) end
    )
  end

  defp workload_case(c, id, workload, inherited) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: @scope,
        id: "startup-" <> id,
        profile: c.profile,
        artifact: c.artifact,
        workload: workload
      )

    {:ok, machine} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = created = idle(machine)
    true = created.reservation.slots == 1 and created.reserved_ports == []
    checkpoint(c, id <> "-created", created)
    {:ok, ^machine} = Machines.create(__MODULE__, spec)
    before = helper(c.tooling, "inventory")
    changed = %{spec | workload: if(workload == nil, do: inherited, else: nil)}

    {:error, %{category: :identity_conflict, evidence: :not_dispatched}} =
      Machines.create(__MODULE__, changed)

    ^before = helper(c.tooling, "inventory")
    has_events = id in ["inherited", "override"]

    cycles =
      Enum.map(0..1, fn cycle ->
        lifecycle(machine, :start, :running)
        count = if has_events, do: cycle + 1, else: 0
        events = startup_events(c, machine, id <> "-events-#{cycle}", count)
        true = length(events) == count
        Enum.each(events, &validate_startup_event(&1, id))
        again = startup_events(c, machine, id <> "-stable-#{cycle}", count)
        true = again == events

        %{state: :running, operation: nil, phase: nil, active_execution: nil} =
          running = idle(machine)

        {:ok, %SmolBox.LogResult{source: :console, lines: lines}} =
          Machines.logs(__MODULE__, machine,
            tail: 100,
            timeout_ms: 5000,
            max_output_bytes: 65_536
          )

        after_logs = idle(machine)
        true = after_logs.spec == running.spec and after_logs.reservation == running.reservation
        checkpoint(c, id <> "-running-#{cycle}", after_logs)
        lifecycle(machine, :stop, :stopped)
        stopped = idle(machine)
        true = stopped.reservation.slots == 1 and stopped.reserved_ports == []

        if cycle == 0 do
          checkpoint(c, id <> "-before-replacement", stopped)
          :ok = Supervisor.terminate_child(c.supervisor, {Runtime, __MODULE__})
          {:ok, _} = Supervisor.restart_child(c.supervisor, {Runtime, __MODULE__})
          ready(c.target.id)
          recovered = idle(machine)

          true =
            recovered.spec == stopped.spec and
              recovered.backend_assignment == stopped.backend_assignment

          true = recovered.reservation == stopped.reservation
        end

        %{
          startup_event_count: count,
          startup_events: events,
          repeated_execution_does_not_relaunch: true,
          vm_running_observed: true,
          console_snapshot_completed: true,
          console_lines: length(lines)
        }
      end)

    lifecycle(machine, :delete, :deleted)
    %{reservation: nil, reserved_ports: []} = idle(machine)
    [] = helper(c.tooling, "inventory")

    %{
      kind: id,
      cycles: cycles,
      duplicate_create_reuses_identity: true,
      changed_workload_rejected_before_dispatch: true,
      retained_across_stopped_runtime_replacement: true,
      owned_deleted: true,
      startup_exit_status_attested: false
    }
  end

  defp startup_events(c, machine, id, expected) do
    program = """
    import json,pathlib,sys,time
    path=pathlib.Path('/workspace/startup-events.jsonl')
    expected=int(sys.argv[1]); deadline=time.monotonic()+8
    while True:
        events=[json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        if len(events)>=expected: break
        assert time.monotonic()<deadline, 'startup marker not observed'
        time.sleep(.05)
    print(json.dumps(events))
    """

    result = execute(c, machine, id, ["python", "-c", program, Integer.to_string(expected)])
    Jason.decode!(result.result.stdout)
  end

  defp validate_startup_event(event, id) do
    expected =
      case id do
        "inherited" ->
          %{
            "kind" => "baked",
            "argv" => ["baked literal; text"],
            "cwd" => "/workspace",
            "override" => "baked",
            "extra" => nil
          }

        "override" ->
          %{
            "kind" => "override",
            "argv" => ["replacement literal; text"],
            "cwd" => "/",
            "override" => "override",
            "extra" => "explicit"
          }
      end

    true = event == Map.merge(expected, %{"uid" => 0, "inherited" => "baked"})
  end

  defp network_case(c) do
    {:ok, mapping} = PortMapping.new(host: c.mapped, guest: 8000)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: @scope,
        id: c.profile.id,
        profile: c.profile,
        artifact: c.artifact,
        ports: [mapping]
      )

    {:ok, machine} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = created = idle(machine)
    true = created.created_machine.network == c.profile.network
    true = created.created_machine.ports == [mapping]
    reserved(c, created)
    checkpoint(c, "created", created)
    {:ok, ^machine} = Machines.create(__MODULE__, spec)
    conflict(c, spec, "created-conflict")

    contents =
      "public-native-network-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    cycles =
      Enum.map(0..1, fn cycle ->
        lifecycle(machine, :start, :running)
        true = helper(c.tooling, "positive")

        program = """
        import socket,json
        reached=[]
        for address in ['198.18.0.10','198.18.0.11']:
            try:
                with socket.create_connection((address,8088),timeout=2) as peer:
                    body=bytearray()
                    while len(body)<256:
                        part=peer.recv(256-len(body))
                        if not part: break
                        body.extend(part)
                    assert bytes(body)==b'smolbox-native-network-fixture\\n'
                reached.append(True)
            except OSError: reached.append(False)
        print(json.dumps(reached))
        """

        result = execute(c, machine, "traffic-#{cycle}", ["python", "-c", program])
        reached = Jason.decode!(result.result.stdout)
        true = reached == [c.profile.network != :offline, false]

        if cycle == 0 do
          execute(c, machine, "write", [
            "python",
            "-c",
            "import pathlib,sys; pathlib.Path('/workspace/native-network.txt').write_text(sys.argv[1])",
            contents
          ])
        end

        launch(c, machine, cycle)
        true = helper(c.tooling, "inbound", [Integer.to_string(c.mapped), contents])
        bindings = helper(c.tooling, "listeners", [Integer.to_string(c.mapped)])
        true = "127.0.0.1:#{c.mapped}" in bindings
        true = Enum.all?(bindings, &(&1 in ["127.0.0.1:#{c.mapped}", "[::1]:#{c.mapped}"]))
        lifecycle(machine, :stop, :stopped)
        stopped = idle(machine)
        reserved(c, stopped)
        checkpoint(c, "stopped-#{cycle}", stopped)

        if cycle == 0 do
          :ok = SmolBox.drain_worker(__MODULE__, c.target.id)
          :ok = Supervisor.terminate_child(c.supervisor, {Runtime, __MODULE__})
          {:ok, _} = Supervisor.restart_child(c.supervisor, {Runtime, __MODULE__})
          ready(c.target.id)
          recovered = idle(machine)

          true =
            recovered.reservation == stopped.reservation and
              recovered.reserved_ports == stopped.reserved_ports and
              recovered.backend_assignment == stopped.backend_assignment

          {:ok, report} = SmolBox.worker_maintenance(__MODULE__, c.target.id)
          true = report.control.mode == :draining and report.reserved.slots == 1

          {:ok, %{mode: :active}} =
            SmolBox.resume_worker(__MODULE__, c.target.id, report.control.version)

          conflict(c, spec, "stopped-replacement-conflict")
        end

        %{
          outbound_reached: reached,
          host_positive_controls: [true, true],
          inbound_reply_verified: true,
          loopback_listeners: bindings
        }
      end)

    lifecycle(machine, :delete, :deleted)
    %{reservation: nil, reserved_ports: []} = idle(machine)
    [] = helper(c.tooling, "inventory")

    %{
      network: if(c.profile.network == :offline, do: "offline", else: "cidr"),
      cycles: cycles,
      reservation_survives_stop_and_runtime_replacement: true,
      draining_survives_runtime_replacement: true,
      conflict_rolls_back_before_dispatch: true,
      duplicate_create_reuses_identity: true,
      owned_deleted: true
    }
  end

  defp reserved(c, record) do
    true = record.reserved_ports == [c.mapped] and record.reservation.slots == 1
    {:ok, report} = SmolBox.worker_maintenance(__MODULE__, c.target.id)
    true = report.reserved.slots == 1
  end

  defp conflict(c, spec, suffix) do
    before = helper(c.tooling, "inventory")
    {:ok, key} = Machines.create(__MODULE__, %{spec | id: spec.id <> "-" <> suffix})

    %{
      state: :conflict,
      worker_id: nil,
      reservation: nil,
      reserved_ports: [],
      created_machine: nil,
      last_error: %{category: :port_conflict}
    } = idle(key)

    ^before = helper(c.tooling, "inventory")
    {:ok, report} = SmolBox.worker_maintenance(__MODULE__, c.target.id)
    true = report.reserved.slots == 1
    lifecycle(key, :delete, :deleted)
  end

  defp execute(c, machine, id, argv) do
    {:ok, command} = Command.new(argv, timeout_secs: 10, workdir: "/workspace")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: @scope,
        id: c.profile.id <> "-" <> id,
        profile: c.profile,
        artifact: c.artifact,
        command: command
      )

    {:ok, handle} = Machines.submit(__MODULE__, machine, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0}} = result} =
      SmolBox.await(__MODULE__, handle, 180_000)

    %{state: :running} = idle(machine)
    result
  end

  defp launch(c, machine, cycle) do
    {:ok, command} =
      Command.new(
        ["python", "-m", "http.server", "8000", "--bind", "0.0.0.0", "--directory", "/workspace"],
        background: true,
        workdir: "/workspace"
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: @scope,
        id: c.profile.id <> "-launch-#{cycle}",
        profile: c.profile,
        artifact: c.artifact,
        command: command
      )

    {:ok, key} = Machines.submit(__MODULE__, machine, spec)

    {:ok, %{state: :launched, result: %SmolBox.LaunchResult{pid: pid}} = result} =
      SmolBox.await(__MODULE__, key, 180_000)

    true = pid > 0
    checkpoint(c, "launch-#{cycle}", result)
    %{state: :running, active_execution: nil} = idle(machine)
  end

  defp lifecycle(key, action, expected, retries \\ 10) do
    current = idle(key)

    case apply(Machines, action, [__MODULE__, key, current.version]) do
      {:ok, _} ->
        %{state: ^expected} = idle(key)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle(key, action, expected, retries - 1)

      error ->
        raise "public lifecycle rejection: #{inspect(error)}"
    end
  end

  defp idle(key), do: elem(Machines.await(__MODULE__, key, 180_000), 1)

  defp ready(id) do
    wait(
      fn ->
        {:ok, workers} = SmolBox.workers(__MODULE__)
        Enum.any?(workers, &(&1.id == id and &1.health_status == :ready))
      end,
      System.monotonic_time(:millisecond) + 180_000
    )
  end

  defp wait(check, deadline) do
    unless check.() do
      true = System.monotonic_time(:millisecond) < deadline
      Process.sleep(50)
      wait(check, deadline)
    end
  end

  defp checkpoint(c, label, record) do
    {:ok, bytes} = Codec.encode(record)
    {:ok, ^record} = Codec.decode(bytes)
    save(c.root, "private-#{c.profile.id}-#{label}.bin", bytes)
  end

  defp save(root, name, bytes) do
    path = Path.join(root, name)
    :ok = File.write(path, bytes, [:exclusive])
    :ok = File.chmod(path, 0o600)
  end

  defp preserve_records(root, {adapter, store}, worker) do
    encoded =
      assignment_records(adapter, store, worker, nil)
      |> Enum.map(fn record ->
        {:ok, bytes} = Codec.encode(record)
        Base.encode64(bytes)
      end)

    save(root, "private-before-shutdown.json", Jason.encode!(encoded))
  end

  defp assignment_records(adapter, store, worker, cursor) do
    {:ok, records, next} = adapter.backend_assignments(store, worker, cursor, 100)
    if next, do: records ++ assignment_records(adapter, store, worker, next), else: records
  end

  defp helper(tooling, action, extra \\ []) do
    program = """
    import sys,json
    sys.path.insert(0,sys.argv[1])
    from native_proof import snapshot
    from network_fixture import positive_controls
    from network_proof import inbound,listeners
    action=sys.argv[2]
    if action=='inventory': result=snapshot()
    elif action=='positive': positive_controls(); result=True
    elif action=='inbound': inbound(int(sys.argv[3]),sys.argv[4].encode()); result=True
    elif action=='listeners': result=listeners(int(sys.argv[3]))
    else: raise AssertionError('unknown ordinary fixture observation')
    print(json.dumps(result))
    """

    {body, 0} = System.cmd("python3", ["-c", program, tooling, action] ++ extra)
    Jason.decode!(body)
  end
end

SmolBox.EmbeddedNetworkProof.run(System.argv())
