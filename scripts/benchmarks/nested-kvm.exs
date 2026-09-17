# Run through a bounded Linux service in an isolated SmolBox 0.1.3 consumer.
# This is a trusted, finite benchmark, not an exhaustion or isolation test.
alias SmolBox.{
  Client,
  Command,
  Error,
  ExecutionSpec,
  Files,
  Identity,
  Machine,
  MachineSpec,
  Profile,
  Worker
}

alias SmolBox.ArtifactStore.Directory
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.Memory

defmodule NestedBenchmark do
  def clock, do: System.monotonic_time(:microsecond)

  def timed(fun) do
    started = clock()
    result = fun.()
    {(clock() - started) / 1000, result}
  end

  def counters(path) do
    Map.new(["cpu.stat", "memory.events", "memory.peak", "cpu.max", "memory.max"], fn file ->
      {file, File.read!(Path.join(path, file))}
    end)
  end
end

true = :os.type() == {:unix, :linux}
[root, label, sample] = System.argv()
true = label in ["direct", "nested"]
true = Regex.match?(~r/\A(?:warmup|[1-6])\z/, sample)
report_path = Path.join(root, "#{label}-#{sample}.json")
false = File.exists?(report_path)
artifact_path = Path.join(root, "python.smolmachine")
artifact_hash = "76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2"
^artifact_hash = Files.sha256(File.read!(artifact_path))
"0.1.3" = to_string(Application.spec(:smolbox, :vsn))

{:ok, worker} =
  Worker.new("bench", "http://localhost",
    unix_socket: Path.join(root, "api.sock"),
    allow_insecure_loopback: true,
    operation_timeout_ms: 180_000,
    receive_timeout_ms: 175_000
  )

{:ok, client} = Client.new(worker)
{:ok, %{version: "1.16.0"}} = Client.health(client)
:ok = Client.readiness(client)
{:ok, []} = Client.list(client)

# Guest monotonic measurements exclude Python interpreter startup and the HTTP
# round trip. File processing includes fsync but is not a cold-disk benchmark.
source = ~S"""
import hashlib, json, os, pathlib, platform, sys, time
mode = sys.argv[1]
start = time.perf_counter_ns()
if mode == 'cpu':
    value = 0
    for i in range(2000000):
        value = (value + i * i) & 0xffffffffffffffff
    result = {'value': value, 'iterations': 2000000}
elif mode == 'file':
    block = b'smolbox-benchmark\n' * 4096
    path = pathlib.Path('/workspace/data.bin')
    with path.open('wb') as f:
        for _ in range(512):
            f.write(block)
        f.flush()
        os.fsync(f.fileno())
    digest = hashlib.sha256()
    with path.open('rb') as f:
        while chunk := f.read(65536):
            digest.update(chunk)
    result = {'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}
    path.unlink()
else:
    raise ValueError(mode)
result.update(mode=mode, guest_ms=(time.perf_counter_ns()-start)/1000000,
              python=platform.python_version(), kernel=platform.release())
text = json.dumps(result, sort_keys=True)
pathlib.Path('/workspace/report.json').write_text(text)
print(text)
"""

group = File.read!(Path.join(root, "worker-cgroup")) |> String.trim()
before_counters = NestedBenchmark.counters(group)

report = %{
  label: label,
  sample: sample,
  recorded_at: DateTime.to_iso8601(DateTime.utc_now()),
  artifact_sha256: artifact_hash,
  source_sha256: Files.sha256(source),
  library_version: "0.1.3",
  runtime_version: "1.16.0",
  counters_before: before_counters,
  host_kernel: System.cmd("uname", ["-r"]) |> elem(0) |> String.trim(),
  elixir: System.version(),
  otp: to_string(:erlang.system_info(:otp_release))
}

File.write!(report_path, Jason.encode!(Map.put(report, :status, "started"), pretty: true))

{:ok, name} = Identity.machine_name("bench")

{:ok, machine_spec} =
  MachineSpec.new(name, artifact_path, cpus: 1, memory_mb: 512, storage_gb: 1, overlay_gb: 1)

{create_ms, {:ok, created}} = NestedBenchmark.timed(fn -> Client.create(client, machine_spec) end)

low_level =
  try do
    {start_ms, {:ok, running}} = NestedBenchmark.timed(fn -> Client.start(client, name) end)
    true = Machine.same_incarnation?(created, running)
    {:ok, tiny} = Command.new(["/bin/true"])

    {first_exec_ms, {:ok, %{exit_code: 0}}} =
      NestedBenchmark.timed(fn -> Client.exec(client, name, tiny) end)

    {tiny_ms, {:ok, %{exit_code: 0}}} =
      NestedBenchmark.timed(fn -> Client.exec(client, name, tiny) end)

    :ok = Client.upload(client, name, "/workspace/bench.py", source, Files.sha256(source))

    results =
      Map.new(["cpu", "file"], fn mode ->
        {:ok, cmd} = Command.new(["python", "/workspace/bench.py", mode], timeout_secs: 60)

        {elapsed, {:ok, %{exit_code: 0, stdout: output}}} =
          NestedBenchmark.timed(fn -> Client.exec(client, name, cmd) end)

        result = Jason.decode!(output)
        {:ok, bytes} = Client.download(client, name, "/workspace/report.json", 4096)
        ^result = Jason.decode!(bytes)
        {mode, Map.put(result, "client_ms", elapsed)}
      end)

    # Direct host VMM descriptors are protected by upstream process hardening.
    # A separate traced pilot proves successful KVM creation; measured runs are
    # untraced. Root inspection is available only inside the disposable guest.
    fds =
      if label == "nested" do
        {captured, 0} = System.cmd("sudo", ["bash", Path.join(root, "capture-kvm.sh"), group])
        true = String.contains?(captured, "kvm-vm")
        true = String.contains?(captured, "kvm-vcpu")
        captured
      else
        captured = File.read!(Path.join(root, "kvm-proof.txt"))
        true = Regex.match?(~r/ioctl\(\d+, KVM_CREATE_VM, 0\)\s+= \d+/, captured)
        true = Regex.match?(~r/ioctl\(\d+, KVM_CREATE_VCPU, 0\)\s+= \d+/, captured)
        captured
      end

    Map.merge(results, %{
      create_ms: create_ms,
      start_ms: start_ms,
      first_exec_ms: first_exec_ms,
      ready_ms: create_ms + start_ms + first_exec_ms,
      tiny_client_ms: tiny_ms,
      kvm_descriptors: String.split(fds, "\n", trim: true)
    })
  after
    {:ok, observed} = Client.inspect_machine(client, name)
    true = Machine.same_incarnation?(created, observed)
    {:ok, _} = Client.stop(client, name)
    :ok = Client.delete(client, name)
    {:error, %Error{category: :not_found}} = Client.inspect_machine(client, name)
  end

{:ok, []} = Client.list(client)

File.write!(
  report_path,
  Jason.encode!(Map.merge(report, %{status: "low_level_complete", low_level: low_level}),
    pretty: true
  )
)

objects_path = Path.join(root, "objects-#{sample}")
File.mkdir!(objects_path)
File.chmod!(objects_path, 0o700)
{:ok, objects} = Directory.new(objects_path)

{:ok, profile} =
  Profile.new("benchmark",
    cpus: 1,
    memory_mb: 512,
    storage_gb: 1,
    overlay_gb: 1,
    host_overhead_mb: 768,
    preparation_ms: 180_000,
    execution_ms: 90_000
  )

artifact = %{
  "id" => "python",
  "path" => artifact_path,
  "sha256" => artifact_hash,
  "architecture" => "x86_64"
}

{:ok, configured} =
  WorkerConfig.new(
    client: client,
    platform: :linux,
    architecture: "x86_64",
    runtime_version: "1.16.0",
    artifacts: [artifact],
    profiles: [profile],
    allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 768},
    capacity: %{slots: 1, cpus: 1, memory_mb: 2048, disk_gb: 2}
  )

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Memory, name: BenchStore},
      {SmolBox,
       name: BenchRuntime,
       namespace: "bench",
       mode: :ephemeral,
       store: {Memory, BenchStore},
       artifact_store: {Directory, objects},
       fingerprint_key: :crypto.strong_rand_bytes(32),
       workers: [configured],
       max_active: 1}
    ],
    strategy: :rest_for_one
  )

:ok = Directory.seed(objects, "bench", "program", source)
{:ok, command} = Command.new(["python", "/workspace/bench.py", "file"], timeout_secs: 60)

{:ok, spec} =
  ExecutionSpec.new(
    scope: "bench",
    id: sample,
    artifact: Map.drop(artifact, ["path"]),
    profile: profile,
    command: command,
    inputs: [
      %{
        "source" => "program",
        "path" => "/workspace/bench.py",
        "size" => byte_size(source),
        "sha256" => Files.sha256(source),
        "mode" => "runtime_default"
      }
    ],
    outputs: [
      %{"destination" => "report", "path" => "/workspace/report.json", "max_bytes" => 4096}
    ]
  )

started = NestedBenchmark.clock()
{:ok, handle} = SmolBox.submit(BenchRuntime, spec)

{:ok, %{state: :completed, result: %{exit_code: 0}, collection: :complete}} =
  SmolBox.await(BenchRuntime, handle, 240_000)

collected_ms = (NestedBenchmark.clock() - started) / 1000
{:ok, output} = Directory.read_output(objects, handle, "report", 4096)
managed_result = Jason.decode!(output)
deadline = NestedBenchmark.clock() + 60_000_000

wait = fn again ->
  {:ok, record} = SmolBox.fetch(BenchRuntime, "bench", sample)

  if record.cleanup == :complete and record.reservation == nil do
    :ok
  else
    true = NestedBenchmark.clock() < deadline
    Process.sleep(10)
    again.(again)
  end
end

:ok = wait.(wait)
complete_ms = (NestedBenchmark.clock() - started) / 1000
{:ok, []} = Client.list(client)
:ok = Supervisor.stop(supervisor)

report =
  Map.merge(report, %{
    status: "passed",
    low_level: low_level,
    managed: %{
      submit_to_collected_ms: collected_ms,
      submit_to_cleanup_ms: complete_ms,
      result: managed_result,
      cleanup: "verified_absent"
    },
    counters_after: NestedBenchmark.counters(group)
  })

File.write!(report_path, Jason.encode!(report, pretty: true))

IO.puts(
  Jason.encode!(%{
    label: label,
    sample: sample,
    ready_ms: low_level.ready_ms,
    managed_ms: complete_ms,
    status: "passed"
  })
)
