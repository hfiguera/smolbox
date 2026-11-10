defmodule SmolBox.Lab.BranchStaticEgress do
  @moduledoc false
  alias SmolBox.{
    Branches,
    BranchPolicy,
    BranchSpec,
    Client,
    Command,
    ExecutionSpec,
    Files,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Runtime,
    Worker
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.Memory

  @timeout 120_000
  @scope "static-egress-proof"
  @probe ~S"""
  command -v nc >/dev/null || exit 1
  errors=$(mktemp) || exit 1
  trap 'rm -f "$errors"' EXIT
  for address in "$@"; do
    # Keep nc's input open long enough for the gateway to relay the response.
    response=$({ printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$address"; sleep 1; } |
      timeout 6 nc -w 4 "$address" 80 2>"$errors")
    status=$?
    if [ "$status" -ne 0 ] && [ -z "$response" ]; then
      printf '%s blocked (exit %s) %s\n' "$address" "$status" "$(head -n 1 "$errors")"
    else
      printf '%s ' "$address"
      printf '%s\n' "$response" | head -n 1 | tr -d '\r'
    fi
  done
  """

  def run(socket, artifact_path, state_dir, mode) do
    {"Linux x86_64\n", 0} = System.cmd("uname", ["-sm"])
    {:ok, endpoint} = Worker.new("proof", "http://localhost", unix_socket: socket)
    {:ok, client} = Client.new(endpoint)
    {:ok, %{version: "1.34.0"}} = Client.health(client)
    {:ok, []} = Client.list(client)
    [approved, _denied] = destinations = destinations(mode)
    {:ok, restricted} = policy(mode, [approved])
    {:ok, control} = policy(mode, destinations)
    IO.puts("Restricted policy #{inspect(restricted)}")
    {:ok, profile} = Profile.new("branch-egress", memory_mb: 512, network: restricted)

    {:ok, control_profile} =
      Profile.new("branch-egress-control", memory_mb: 512, network: control)

    {:ok, policy} =
      BranchPolicy.new(id: "held", resources: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 5})

    artifact = %{
      "id" => "bare",
      "sha256" => Files.sha256(File.read!(artifact_path)),
      "architecture" => "x86_64"
    }

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        platform: :linux,
        architecture: "x86_64",
        profiles: [profile, control_profile],
        artifacts: [Map.put(artifact, "path", artifact_path)],
        branch_policies: [policy],
        capacity: %{slots: 8, cpus: 8, memory_mb: 8192, disk_gb: 64},
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 128}
      )

    {:ok, store} = Memory.start_link([])
    objects_path = Path.join(state_dir, "proof-objects")
    File.mkdir_p!(objects_path)
    File.chmod!(objects_path, 0o700)
    {:ok, objects} = Directory.new(objects_path)

    {:ok, runtime} =
      Runtime.start_link(
        name: __MODULE__,
        namespace: "egress",
        mode: :ephemeral,
        store: {Memory, store},
        artifact_store: {Directory, objects},
        fingerprint_key: :crypto.strong_rand_bytes(32),
        workers: [worker],
        lease_ms: 30_000
      )

    try do
      exercise(runtime, artifact, {profile, control_profile}, policy, state_dir, destinations)
      {:ok, []} = Client.list(client)
      {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(store, "proof")
      IO.puts("PASS: worker inventory empty and reservations released")
    after
      Supervisor.stop(runtime)
    end
  end

  defp destinations(:cidrs), do: ["1.1.1.1", "1.0.0.1"]
  defp destinations(:hostnames), do: ["one.one.one.one", "example.com"]

  defp policy(:cidrs, destinations),
    do: NetworkPolicy.new(cidrs: Enum.map(destinations, &(&1 <> "/32")))

  defp policy(:hostnames, destinations), do: NetworkPolicy.new(hosts: destinations)

  defp exercise(runtime, artifact, {profile, control_profile}, policy, state_dir, destinations) do
    control = boot(runtime, "control", artifact, control_profile, false)
    expect_probe(runtime, control, destinations, "control before branching", :both_reachable)

    source = boot(runtime, "source", artifact, profile, true)

    "" =
      execute(runtime, source, "park", [
        "/bin/sh",
        "-c",
        """
        smolvm-branch-ready -- /bin/true </dev/null >/tmp/branch-ready.log 2>&1 &
        for n in 1 2 3 4 5; do
          test -s /run/smolvm/forkpoint/ready && exit 0
          sleep 1
        done
        cat /tmp/branch-ready.log >&2
        exit 1
        """
      ])

    children =
      for id <- ~w(left right) do
        {:ok, spec} = BranchSpec.new(id: id, policy: policy, idle: true, hold: true)
        {:ok, child} = Branches.create(runtime, source, spec)
        {:ok, %{branch: %{state: :held}}} = Branches.await(runtime, child, @timeout)
        IO.puts("#{id}: held")
        child
      end

    for {_, id} = child <- children do
      {:ok, _} = Branches.release(runtime, child, machine(runtime, child).version)
      {:ok, %{branch: %{state: :released}}} = Branches.await(runtime, child, @timeout)
      expect_probe(runtime, child, destinations, id <> " after release", :restricted)
      transition(runtime, child, :stop, :stopped)
      transition(runtime, child, :start, :running)
      expect_probe(runtime, child, destinations, id <> " after stop/start", :restricted)
      transition(runtime, child, :stop, :stopped)
      transition(runtime, child, :delete, :deleted)
      {:ok, _} = Branches.retire(runtime, child, quiesced: true)
    end

    transition(runtime, source, :stop, :stopped)
    transition(runtime, source, :delete, :deleted)
    expect_probe(runtime, control, destinations, "control after restart probes", :both_reachable)
    transition(runtime, control, :stop, :stopped)
    transition(runtime, control, :delete, :deleted)

    for child <- children do
      %{machine_name: name, branch: %{source_machine: %{name: source_name}}} =
        machine(runtime, child)

      false =
        Enum.any?([name, source_name], fn machine_name ->
          hash = machine_name |> Files.sha256() |> binary_part(0, 16)
          File.exists?(Path.join([state_dir, ".cache", "smolvm", "vms", hash]))
        end)

      {:ok, _} = Branches.release_storage(runtime, child, backing_removed: true)
    end
  end

  defp boot(runtime, id, artifact, profile, static_egress) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: @scope,
        id: id,
        artifact: artifact,
        profile: profile,
        branch_static_egress: static_egress
      )

    {:ok, handle} = Machines.create(runtime, spec)
    %{state: :created} = machine(runtime, handle)
    transition(runtime, handle, :start, :running)
    handle
  end

  defp expect_probe(runtime, handle, [approved, denied] = destinations, label, expected) do
    result =
      execute(
        runtime,
        handle,
        "probe-" <> Integer.to_string(System.unique_integer([:positive])),
        ["/bin/sh", "-c", @probe, "probe" | destinations]
      )

    IO.puts("#{label}\n#{result}")
    [approved_result, denied_result] = String.split(result, "\n", trim: true)
    true = String.starts_with?(approved_result, approved <> " HTTP/")

    case expected do
      :both_reachable ->
        true = String.starts_with?(denied_result, denied <> " HTTP/")

      :restricted ->
        true = String.starts_with?(denied_result, denied <> " blocked (exit ")
    end
  end

  defp execute(runtime, handle, id, argv) do
    %{spec: spec} = machine(runtime, handle)
    {:ok, command} = Command.new(argv, timeout_secs: 30)

    {:ok, execution} =
      ExecutionSpec.new(
        scope: @scope,
        id: id,
        artifact: spec.artifact,
        profile: spec.profile,
        command: command
      )

    {:ok, request} = Machines.submit(runtime, handle, execution)
    {:ok, result} = SmolBox.await(runtime, request, @timeout)
    %{state: :completed, result: %{exit_code: 0, stdout: stdout}} = result
    machine(runtime, handle)
    String.trim(stdout)
  end

  defp transition(runtime, handle, action, expected, retries \\ 10) do
    case apply(Machines, action, [runtime, handle, machine(runtime, handle).version]) do
      {:ok, _} ->
        %{state: ^expected} = machine(runtime, handle)

      {:error, %{category: :stale_version}} when retries > 0 ->
        transition(runtime, handle, action, expected, retries - 1)
    end
  end

  defp machine(runtime, handle) do
    {:ok, record} = Machines.await(runtime, handle, @timeout)
    record
  end
end

case System.argv() do
  [socket, artifact, state_dir] ->
    SmolBox.Lab.BranchStaticEgress.run(socket, artifact, state_dir, :cidrs)

  [socket, artifact, state_dir, "hostnames"] ->
    SmolBox.Lab.BranchStaticEgress.run(socket, artifact, state_dir, :hostnames)

  _ ->
    raise ArgumentError, "expected SOCKET ARTIFACT STATE_DIR [hostnames]"
end
