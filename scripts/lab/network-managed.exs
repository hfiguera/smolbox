# The worker and controlled responders must already be running in the nested lab.
import ExUnit.Assertions
alias SmolBox.{Client, Command, ExecutionSpec, NetworkPolicy, Profile, Runtime, Worker}
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.{Codec, Memory}
assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
{:ok, policy} = NetworkPolicy.new(hosts: ["allowed.smolbox.test"])

{:ok, profile} =
  Profile.new("fixture-network-v1",
    network: policy,
    preparation_ms: 120_000,
    execution_ms: 30_000,
    host_overhead_mb: 768
  )

{:ok, endpoint} =
  Worker.new("network-lab", "http://localhost",
    unix_socket: "/srv/sbq/run/api.sock",
    receive_timeout_ms: 115_000,
    operation_timeout_ms: 150_000
  )

{:ok, client} = Client.new(endpoint)

artifact = %{
  "id" => "python",
  "architecture" => "x86_64",
  "sha256" => "76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2"
}

{:ok, worker} =
  WorkerConfig.new(
    client: client,
    runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0"),
    platform: :linux,
    architecture: "x86_64",
    profiles: [profile],
    artifacts: [Map.put(artifact, "path", "/opt/smolbox/catalog/python.smolmachine")],
    capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 2},
    allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768}
  )

{:ok, store} = Memory.start_link([])
root = "/home/lab/qualification/network-artifacts"
File.mkdir_p!(root)
File.chmod!(root, 0o700)
{:ok, artifacts} = SmolBox.ArtifactStore.Directory.new(root)

{:ok, runtime} =
  Runtime.start_link(
    name: SmolBox.NetworkLab,
    namespace: "netlab",
    store: {Memory, store},
    mode: :ephemeral,
    workers: [worker],
    artifact_store: {SmolBox.ArtifactStore.Directory, artifacts},
    fingerprint_key: :crypto.strong_rand_bytes(32)
  )

{:ok, command} =
  Command.new(
    [
      "python",
      "-c",
      "import socket; s=socket.create_connection(('allowed.smolbox.test',8088),2); print(s.recv(64).decode().strip()); s.close()"
    ],
    timeout_secs: 10
  )

{:ok, spec} =
  ExecutionSpec.new(
    scope: "network",
    id: "managed",
    artifact: artifact,
    command: command,
    profile: profile
  )

assert {:ok, _} = SmolBox.submit(runtime, spec)
assert {:ok, result} = SmolBox.await(runtime, {"network", "managed"}, 180_000)
assert result.state == :completed
assert result.result.exit_code == 0
assert result.result.stdout =~ "fixture-ok"

result =
  Enum.reduce_while(1..300, result, fn _attempt, _previous ->
    {:ok, current} = SmolBox.fetch(runtime, "network", "managed")

    if current.cleanup == :complete and current.reservation == nil do
      {:halt, current}
    else
      Process.sleep(100)
      {:cont, current}
    end
  end)

assert result.cleanup == :complete
assert result.reservation == nil
assert result.created_machine.network == policy
assert {:ok, bytes} = Codec.encode(result)
assert {:ok, ^result} = Codec.decode(bytes)
assert {:ok, {"network", "managed"}} = SmolBox.submit(runtime, spec)
assert {:ok, ^result} = SmolBox.fetch(runtime, "network", "managed")
assert {:ok, []} = Client.list(client)
Supervisor.stop(runtime)
GenServer.stop(store)

File.write!(
  "/home/lab/qualification/network-managed.json",
  Jason.encode!(
    %{
      status: "passed",
      runtime: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0"),
      command_exit: 0,
      cleanup: "complete",
      duplicate_submission: "same_execution",
      persisted_policy: true,
      inventory: []
    },
    pretty: true
  )
)

IO.puts("Managed network execution, durable codec, duplicate identity and cleanup passed")
