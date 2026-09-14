# SmolBox 0.1.3 / smolvm 1.16.0: ordinary network report example.
# Run in an Elixir application with {:smolbox, "~> 0.1.3"} installed.
# Prepare a dedicated empty local worker, an approved native Python artifact
# with neutral /bin/true startup, working host resize2fs and verified 1/1 GiB
# allocation floors. Retain the worker's strict egress floor and private API.
# Python needs its standard library and a working certificate trust store.
# Set SMOLBOX_RUNTIME_URL, optional SMOLBOX_RUNTIME_SOCKET,
# SMOLBOX_PYTHON_ARTIFACT, SMOLBOX_PYTHON_SHA256, and SMOLBOX_DEMO_DIR (mode 0700).
# See the article and versioned getting-started guide for worker preparation.
# Use IEx: Code.require_file("network-report.exs"). On error, keep IEx and the
# worker running to inspect the original execution. Do not blindly rerun.
# Memory mode is ephemeral; use a durable adapter in applications needing recovery.

alias SmolBox.{Command, ExecutionSpec, Files, NetworkPolicy, Profile, Worker}
alias SmolBox.ArtifactStore.Directory
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.Memory

artifact_path = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")
approved_sha256 = System.fetch_env!("SMOLBOX_PYTHON_SHA256")

actual_sha256 =
  artifact_path
  |> File.stream!(65_536)
  |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
  |> :crypto.hash_final()
  |> Base.encode16(case: :lower)

true = actual_sha256 == approved_sha256

{platform, architecture} =
  case :os.type() do
    {:unix, :darwin} -> {:macos, "aarch64"}
    {:unix, :linux} -> {:linux, "x86_64"}
  end

worker_options = [
  allow_insecure_loopback: true,
  operation_timeout_ms: 150_000,
  receive_timeout_ms: 115_000
]

worker_options =
  case System.get_env("SMOLBOX_RUNTIME_SOCKET") do
    nil -> worker_options
    socket -> Keyword.put(worker_options, :unix_socket, socket)
  end

{:ok, worker} =
  Worker.new("demo-worker", System.fetch_env!("SMOLBOX_RUNTIME_URL"), worker_options)

{:ok, client} = SmolBox.Client.new(worker)
runtime_version = System.get_env("SMOLBOX_RUNTIME_VERSION", "1.16.0")
{:ok, %{version: ^runtime_version}} = SmolBox.Client.health(client)
:ok = SmolBox.Client.readiness(client)
{:ok, []} = SmolBox.Client.list(client)

{:ok, network} = NetworkPolicy.new(hosts: ["earthquake.usgs.gov"])

{:ok, profile} =
  Profile.new("earthquake-report-v1",
    network: network,
    storage_gb: 1,
    overlay_gb: 1,
    host_overhead_mb: 768,
    preparation_ms: 120_000,
    execution_ms: 30_000
  )

artifact = %{
  "id" => "demo-python-v1",
  "sha256" => approved_sha256,
  "architecture" => architecture,
  "path" => artifact_path
}

{:ok, configured_worker} =
  WorkerConfig.new(
    client: client,
    platform: platform,
    architecture: architecture,
    runtime_version: runtime_version,
    artifacts: [artifact],
    profiles: [profile],
    allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768},
    capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 2}
  )

{:ok, objects} = Directory.new(System.fetch_env!("SMOLBOX_DEMO_DIR"))

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Memory, name: SmolBoxDemo.Store},
      {SmolBox,
       name: SmolBoxDemo.Runtime,
       namespace: "sbxdemo",
       mode: :ephemeral,
       store: {Memory, SmolBoxDemo.Store},
       artifact_store: {Directory, objects},
       fingerprint_key: :crypto.strong_rand_bytes(32),
       workers: [configured_worker],
       max_active: 1}
    ],
    strategy: :rest_for_one
  )

scope = "demo"
id = "report-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
source_ref = "source-" <> id

source = ~S"""
import hashlib
import json
import urllib.request
from pathlib import Path

class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

url = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson"
request = urllib.request.Request(url, headers={"User-Agent": "SmolBox-example/0.1.3"})
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())
with opener.open(request, timeout=10) as response:
    raw = response.read(1_048_577)
if len(raw) > 1_048_576:
    raise ValueError("Feed exceeds the example's 1 MiB input budget")
feed = json.loads(raw)
magnitudes = [f["properties"]["mag"] for f in feed["features"]
              if isinstance(f["properties"]["mag"], (int, float))]
report = {
    "source_url": url,
    "feed_generated_ms": feed["metadata"]["generated"],
    "source_sha256": hashlib.sha256(raw).hexdigest(),
    "download_bytes": len(raw),
    "event_count": len(feed["features"]),
    "maximum_magnitude": max(magnitudes, default=None),
}
Path("/workspace/report.json").write_text(json.dumps(report, indent=2) + "\n")
print("report written")
"""

:ok = Directory.seed(objects, scope, source_ref, source)

{:ok, command} = Command.new(["python", "/workspace/main.py"], timeout_secs: 25)

{:ok, spec} =
  ExecutionSpec.new(
    scope: scope,
    id: id,
    artifact: Map.drop(artifact, ["path"]),
    profile: profile,
    command: command,
    inputs: [
      %{
        "source" => source_ref,
        "path" => "/workspace/main.py",
        "size" => byte_size(source),
        "sha256" => Files.sha256(source),
        "mode" => "runtime_default"
      }
    ],
    outputs: [
      %{
        "destination" => "report",
        "path" => "/workspace/report.json",
        "max_bytes" => 4096
      }
    ]
  )

{:ok, handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)
{:ok, ^handle} = SmolBox.submit(SmolBoxDemo.Runtime, spec)
{:ok, record} = SmolBox.await(SmolBoxDemo.Runtime, handle, 180_000)
%{state: :completed, result: %{exit_code: 0}, collection: :complete} = record
IO.write(record.result.stdout)
{:ok, report} = Directory.read_output(objects, handle, "report", 4096)
IO.puts(report)
File.write!(Path.join(System.fetch_env!("SMOLBOX_DEMO_DIR"), "observed-report.json"), report)

# await/3 returns the command/collection outcome before cleanup may finish.
wait_for_cleanup = fn again, deadline ->
  {:ok, current} = SmolBox.fetch(SmolBoxDemo.Runtime, scope, id)

  cond do
    current.cleanup == :complete and current.reservation == nil ->
      current

    System.monotonic_time(:millisecond) >= deadline ->
      raise "Cleanup is still pending. Keep IEx open and inspect the runtime."

    true ->
      Process.sleep(100)
      again.(again, deadline)
  end
end

cleaned =
  wait_for_cleanup.(wait_for_cleanup, System.monotonic_time(:millisecond) + 60_000)

IO.inspect(Map.take(cleaned, [:state, :collection, :cleanup, :reservation]),
  label: "finished"
)

true = cleaned.created_machine.network == network
{:ok, []} = SmolBox.Client.list(client)

File.write!(
  Path.join(System.fetch_env!("SMOLBOX_DEMO_DIR"), "validation.json"),
  Jason.encode!(
    %{
      status: "passed",
      library_version: to_string(Application.spec(:smolbox, :vsn)),
      runtime_version: runtime_version,
      platform: platform,
      architecture: architecture,
      artifact_sha256: approved_sha256,
      network: Map.from_struct(network),
      same_handle_on_duplicate: true,
      state: cleaned.state,
      collection: cleaned.collection,
      cleanup: cleaned.cleanup,
      reservation_released: cleaned.reservation == nil,
      empty_worker: true,
      checked_at: DateTime.to_iso8601(DateTime.utc_now())
    },
    pretty: true
  )
)

:ok = Supervisor.stop(supervisor)
