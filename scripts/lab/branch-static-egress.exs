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
  alias SmolBox.Embedded.Config
  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.{Codec, Memory}

  defmodule HTTPSResolver do
    @behaviour SmolBox.BranchHTTPSCredentials
    @impl true
    def resolve(%{id: id, host: "httpbingo.org"}, grants),
      do: Agent.get(grants, &Map.fetch(&1, id))

    def resolve(_, _), do: :error
  end

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

  def run(backend, artifact_path, state_dir, mode) do
    {"Linux x86_64\n", 0} = System.cmd("uname", ["-sm"])
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

    options = [
      platform: :linux,
      architecture: "x86_64",
      profiles: [profile, control_profile],
      branch_policies: [policy],
      capacity: %{slots: 8, cpus: 8, memory_mb: 8192, disk_gb: 64},
      allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 128}
    ]

    {options, scenario} =
      if mode == :credentials do
        {:ok, grants} =
          Agent.start_link(fn -> %{"left" => "left-test-key", "right" => "right-test-key"} end)

        {Keyword.put(options, :branch_https_credentials, {HTTPSResolver, grants}),
         {:credentials, grants}}
      else
        {options, mode}
      end

    {worker, verify_empty} =
      worker(backend, Map.put(artifact, "path", artifact_path), state_dir, options)

    verify_empty.()

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
      exercise(
        runtime,
        artifact,
        {profile, control_profile},
        policy,
        state_dir,
        destinations,
        scenario
      )

      verify_empty.()
      {:ok, %{slots: 0, disk_gb: 0}} = Memory.usage(store, "proof")
      IO.puts("PASS: worker inventory empty and reservations released")
    after
      Supervisor.stop(runtime)
    end
  end

  defp worker({:http, socket}, artifact, _state_dir, options) do
    {:ok, endpoint} = Worker.new("proof", "http://localhost", unix_socket: socket)
    {:ok, client} = Client.new(endpoint)
    {:ok, %{version: "1.34.0"}} = Client.health(client)
    {:ok, worker} = WorkerConfig.new([client: client, artifacts: [artifact]] ++ options)
    {worker, fn -> {:ok, []} = Client.list(client) end}
  end

  defp worker({:embedded, package}, artifact, state_dir, options) do
    cache = Path.join(state_dir, ".cache")
    data = Path.join(state_dir, ".local/share")
    ^cache = System.fetch_env!("XDG_CACHE_HOME")
    ^data = System.fetch_env!("XDG_DATA_HOME")
    config = Path.join(state_dir, ".config")
    ^config = System.fetch_env!("XDG_CONFIG_HOME")
    false = File.exists?(Path.join(data, "smolvm"))
    verify_empty = fn -> [] = Path.wildcard(Path.join(cache, "smolvm/vms/*/name")) end

    manifest_bytes = File.read!(Path.join(package, "package.json"))
    manifest = Jason.decode!(manifest_bytes)
    sdk = manifest["policy"]["sdk"]
    %{"sdk_version" => "1.34.0", "feature_versions" => %{"branch_static_egress" => 1}} = sdk
    artifact = Map.put(artifact, "max_bytes", File.stat!(artifact["path"]).size)

    {:ok, worker} =
      Config.new(
        [
          id: "proof",
          bridge: :port,
          package_path: package,
          package_manifest_sha256: Files.sha256(manifest_bytes),
          package_identity: manifest["identity"],
          sdk_identity: sdk,
          domain_generation: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
          allow_initialize: true,
          artifacts: [artifact]
        ] ++ options
      )

    {worker, verify_empty}
  end

  defp destinations(:credentials), do: ["httpbingo.org", "example.com"]

  defp destinations(:cidrs), do: ["1.1.1.1", "1.0.0.1"]
  defp destinations(:hostnames), do: ["one.one.one.one", "example.com"]

  defp policy(:cidrs, destinations),
    do: NetworkPolicy.new(cidrs: Enum.map(destinations, &(&1 <> "/32")))

  defp policy(mode, destinations) when mode in [:hostnames, :credentials],
    do: NetworkPolicy.new(hosts: destinations)

  defp exercise(
         runtime,
         artifact,
         {profile, control_profile},
         policy,
         state_dir,
         destinations,
         mode
       )
       when mode in [:cidrs, :hostnames] do
    control = boot(runtime, "control", artifact, control_profile, false)
    expect_probe(runtime, control, destinations, "control before branching", :both_reachable)

    source = boot(runtime, "source", artifact, profile, true)

    park(runtime, source)

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

    cleanup(runtime, source, control, children, state_dir, destinations, mode)
  end

  defp exercise(
         runtime,
         artifact,
         {profile, control_profile},
         policy,
         state_dir,
         destinations,
         {:credentials, grants}
       ) do
    control = boot(runtime, "control", artifact, control_profile, false)
    control_probe(runtime, control, destinations, :credentials, "control before branching")
    source = boot(runtime, "source", artifact, profile, :credentials)
    park(runtime, source)

    children =
      for id <- ~w(left right unbound) do
        {:ok, spec} = BranchSpec.new(id: id, policy: policy, idle: true, hold: true)
        {:ok, child} = Branches.create(runtime, source, spec)
        {:ok, %{branch: %{state: :held}}} = Branches.await(runtime, child, @timeout)
        IO.puts("#{id}: held")
        child
      end

    for {_, id} = child <- children do
      {:ok, _} = Branches.release(runtime, child, machine(runtime, child).version)

      if id == "unbound" do
        {:ok, %{branch: %{state: :held}, last_error: %{category: :authentication}}} =
          Branches.await(runtime, child, @timeout)

        IO.puts("unbound: denied release and retained held state")
      else
        {:ok, %{branch: %{state: :released}}} = Branches.await(runtime, child, @timeout)
        credential_probe(runtime, child, id <> "-test-key", id <> " after release")
        transition(runtime, child, :stop, :stopped)

        prove_revoked_restart(runtime, child, id, grants)

        transition(runtime, child, :start, :running)
        credential_probe(runtime, child, id <> "-test-key", id <> " after stop/start")
        transition(runtime, child, :stop, :stopped)
      end

      transition(runtime, child, :delete, :deleted)
      {:ok, _} = Branches.retire(runtime, child, quiesced: true)
    end

    cleanup(runtime, source, control, children, state_dir, destinations, :credentials)
  end

  defp prove_revoked_restart(runtime, child, "left" = id, grants) do
    Agent.update(grants, &Map.delete(&1, id))
    {:ok, _} = Machines.start(runtime, child, machine(runtime, child).version)

    %{state: :stopped, last_error: %{category: :authentication, evidence: :not_dispatched}} =
      machine(runtime, child)

    IO.puts("left: revoked binding denied restart before native dispatch")
    Agent.update(grants, &Map.put(&1, id, id <> "-test-key"))
  end

  defp prove_revoked_restart(_runtime, _child, _id, _grants), do: :ok

  defp cleanup(runtime, source, control, children, state_dir, destinations, mode) do
    transition(runtime, source, :stop, :stopped)
    transition(runtime, source, :delete, :deleted)
    control_probe(runtime, control, destinations, mode, "control after restart probes")
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

  defp park(runtime, source) do
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
  end

  defp control_probe(runtime, control, destinations, :credentials, label) do
    for host <- destinations do
      output =
        execute(
          runtime,
          control,
          "control-" <> host <> "-" <> Integer.to_string(System.unique_integer([:positive])),
          [
            "/bin/sh",
            "-c",
            ~S(timeout 15 wget -q -O - "https://$1/" >/dev/null && printf reachable),
            "probe",
            host
          ]
        )

      "reachable" = output
    end

    IO.puts(label <> ": both HTTPS destinations reachable")
  end

  defp control_probe(runtime, control, destinations, _mode, label),
    do: expect_probe(runtime, control, destinations, label, :both_reachable)

  defp credential_probe(runtime, child, key, label) do
    output =
      execute(runtime, child, "https-" <> Integer.to_string(System.unique_integer([:positive])), [
        "/bin/sh",
        "-c",
        ~S(timeout 15 wget -q -O - https://httpbingo.org/headers)
      ])

    %{"headers" => headers} = Jason.decode!(output)
    ["Bearer " <> ^key] = headers["Authorization"]

    blocked =
      execute(runtime, child, "deny-" <> Integer.to_string(System.unique_integer([:positive])), [
        "/bin/sh",
        "-c",
        ~S(if timeout 10 wget -q -O - https://example.com/ >/tmp/denied-response 2>/tmp/denied-error; then exit 1; fi; test ! -s /tmp/denied-response && printf blocked)
      ])

    "blocked" = blocked
    IO.puts(label <> ": own credential verified at approved HTTPS host; denied host blocked")
  end

  defp boot(runtime, id, artifact, profile, static_egress) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: @scope,
        id: id,
        artifact: artifact,
        profile: profile,
        branch_static_egress: static_egress == true,
        checkpointable: static_egress == :credentials
      )

    {:ok, handle} = Machines.create(runtime, spec)
    true = machine(runtime, handle).state in [:created, :stopped]
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
    roundtrip(result)

    case result do
      %{state: :completed, result: %{exit_code: 0, stdout: stdout}} ->
        machine(runtime, handle)
        String.trim(stdout)

      %{result: %SmolBox.Result{} = failed} ->
        raise "guest probe failed: #{inspect(Map.take(Map.from_struct(failed), [:exit_code, :stdout, :stderr]))}"

      _ ->
        raise "guest execution failed: #{inspect(Map.take(result, [:state, :last_error, :failure]))}"
    end
  end

  defp transition(runtime, handle, action, expected, retries \\ 10) do
    case apply(Machines, action, [runtime, handle, machine(runtime, handle).version]) do
      {:ok, _} ->
        record = machine(runtime, handle)

        if record.state != expected,
          do:
            raise(
              "#{action} #{inspect(handle)} reached #{inspect({record.state, record.last_error})}"
            )

        record

      {:error, %{category: :stale_version}} when retries > 0 ->
        transition(runtime, handle, action, expected, retries - 1)
    end
  end

  defp machine(runtime, handle) do
    {:ok, record} = Machines.await(runtime, handle, @timeout)
    roundtrip(record)
  end

  defp roundtrip(
         %{backend_assignment: %{creation: %{"features" => %{"branch_https" => true}}}} = record
       ) do
    {:ok, <<"smolbox-record-v53\0", _::binary>> = encoded} = Codec.encode(record)
    {:ok, ^record} = Codec.decode(encoded)
    record
  end

  defp roundtrip(record), do: record
end

case System.argv() do
  [socket, artifact, state_dir] ->
    SmolBox.Lab.BranchStaticEgress.run({:http, socket}, artifact, state_dir, :cidrs)

  [socket, artifact, state_dir, "hostnames"] ->
    SmolBox.Lab.BranchStaticEgress.run({:http, socket}, artifact, state_dir, :hostnames)

  ["--embedded", package, artifact, state_dir] ->
    SmolBox.Lab.BranchStaticEgress.run({:embedded, package}, artifact, state_dir, :cidrs)

  ["--embedded", package, artifact, state_dir, "credentials"] ->
    SmolBox.Lab.BranchStaticEgress.run({:embedded, package}, artifact, state_dir, :credentials)

  ["--embedded", package, artifact, state_dir, "hostnames"] ->
    SmolBox.Lab.BranchStaticEgress.run({:embedded, package}, artifact, state_dir, :hostnames)

  _ ->
    raise ArgumentError,
          "expected SOCKET or --embedded PACKAGE, followed by ARTIFACT STATE_DIR [hostnames|credentials]"
end
