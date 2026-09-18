# Storage exhaustion: only run in the disposable, constrained Linux lab.
# Current checkouts admit 1.16.1 explicitly; only historical checkouts need the candidate patch.
defmodule SmolBox.DiscardProbeTransport do
  @moduledoc false
  @behaviour SmolBox.Transport
  alias SmolBox.Transport.Req

  @impl SmolBox.Transport
  def request(worker, request) do
    if request.method == :delete do
      path = System.get_env("SMOLBOX_DISCARD_STORAGE", "/srv/sbq/cache")
      {bytes, 0} = System.cmd("df", ["-B1", "--output=avail", path])
      available = bytes |> String.split() |> List.last() |> String.to_integer()
      :persistent_term.put({__MODULE__, :available_before_delete}, available)
    end

    if String.ends_with?(request.path, "/stop") do
      if System.get_env("SMOLBOX_DISCARD_MODE", "completed") == "completed",
        do: raise("Managed discard unexpectedly attempted graceful stop")

      :persistent_term.put({__MODULE__, :stop_observed}, true)
    end

    Req.request(worker, observe_output(request))
  end

  defp observe_output(%{mode: {:sse, max, callback}} = request) do
    observer = :persistent_term.get({__MODULE__, :observer})

    notify = fn event ->
      if match?({:stdout, _}, event), do: send(observer, {:probe_output, elem(event, 1)})
      callback.(event)
    end

    %{request | mode: {:sse, max, notify}}
  end

  defp observe_output(request), do: request
end

import ExUnit.Assertions
alias SmolBox.{Client, Command, ExecutionSpec, Profile, Runtime, Worker}
alias SmolBox.Runtime.WorkerConfig
alias SmolBox.Store.{Codec, Memory}
assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
assert {"kvm\n", 0} = System.cmd("systemd-detect-virt", [])
label = System.fetch_env!("SMOLBOX_DISCARD_LABEL")
assert Regex.match?(~r/\A[a-z0-9-]{1,40}\z/, label)
mode = System.get_env("SMOLBOX_DISCARD_MODE", "completed")
assert mode in ["completed", "unknown"]
:persistent_term.put({SmolBox.DiscardProbeTransport, :observer}, self())
report_path = "/home/lab/qualification/#{label}.json"
refute File.exists?(report_path)

{:ok, profile} =
  Profile.new("discard-v1",
    cpus: 2,
    memory_mb: 256,
    storage_gb: 20,
    overlay_gb: 10,
    preparation_ms: 120_000,
    execution_ms: 30_000,
    host_overhead_mb: 768
  )

{:ok, endpoint} =
  Worker.new("discard-lab", "http://localhost",
    unix_socket: System.get_env("SMOLBOX_RUNTIME_SOCKET", "/srv/sbq/run/api.sock"),
    receive_timeout_ms: 115_000,
    operation_timeout_ms: 150_000
  )

{:ok, client} = Client.new(endpoint, transport: SmolBox.DiscardProbeTransport)

artifact = %{
  "id" => "python",
  "architecture" => "x86_64",
  "sha256" => "76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2"
}

{:ok, worker} =
  WorkerConfig.new(
    client: client,
    runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.16.0"),
    platform: :linux,
    architecture: "x86_64",
    profiles: [profile],
    artifacts: [Map.put(artifact, "path", "/opt/smolbox/catalog/python.smolmachine")],
    capacity: %{slots: 1, cpus: 2, memory_mb: 1024, disk_gb: 30},
    allocation_floor: %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768}
  )

{:ok, store} = Memory.start_link([])
root = "/home/lab/qualification/discard-artifacts-#{label}"
File.mkdir_p!(root)
File.chmod!(root, 0o700)
{:ok, artifacts} = SmolBox.ArtifactStore.Directory.new(root)

{:ok, runtime} =
  Runtime.start_link(
    name: SmolBox.DiscardLab,
    namespace: "discardlab",
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
      """
      import json,os
      written=0
      failure=None
      try:
          with open('/workspace/fill','wb',buffering=0) as f:
              for i in range(1024):
                  f.write(b'x'*1048576)
                  os.fsync(f.fileno())
                  written+=1048576
      except OSError as error: failure=error.errno
      print(json.dumps({'written':written,'errno':failure}),flush=True)
      """ <> if(mode == "unknown", do: "import time; time.sleep(45)\n", else: "")
    ],
    timeout_secs: 25
  )

{:ok, spec} =
  ExecutionSpec.new(
    scope: "discard",
    id: "managed",
    artifact: artifact,
    command: command,
    profile: profile
  )

assert {:ok, handle} = SmolBox.submit(runtime, spec)

if mode == "unknown" do
  receive do
    {:probe_output, output} ->
      fill = Jason.decode!(output)
      assert fill["errno"] in [5, 28]
      :persistent_term.put({SmolBox.DiscardProbeTransport, :fill}, fill)
  after
    150_000 -> flunk("Storage workload did not produce its bounded observation")
  end

  assert {:ok, ^handle} = SmolBox.cancel(runtime, spec.scope, spec.id)
end

assert {:ok, result} = SmolBox.await(runtime, {"discard", "managed"}, 180_000)

if mode == "completed" do
  assert result.state == :completed
  assert result.result.exit_code == 0
  assert Jason.decode!(result.result.stdout)["errno"] in [5, 28]
else
  assert result.state == :unknown
  assert result.result == nil
end

result =
  Enum.reduce_while(1..300, result, fn _attempt, _previous ->
    {:ok, current} = SmolBox.fetch(runtime, "discard", "managed")

    if current.cleanup in [:complete, :failed] do
      {:halt, current}
    else
      Process.sleep(100)
      {:cont, current}
    end
  end)

assert result.created_machine.network == :offline
assert {:ok, bytes} = Codec.encode(result)
assert {:ok, ^result} = Codec.decode(bytes)
assert {:ok, ^handle} = SmolBox.submit(runtime, spec)

account =
  if System.get_env("SMOLBOX_DISCARD_STORAGE") == "/srv/smolbox-cleanup/data",
    do: "smolbox-cleanup",
    else: "smolbox-qual"

{kvm_descriptors, 0} =
  System.cmd("sudo", ["bash", "/opt/smolbox/source/scripts/lab/kvm-fds.sh", account])

report =
  if mode == "completed" do
    assert :persistent_term.get({SmolBox.DiscardProbeTransport, :available_before_delete}) == 0
    assert result.cleanup == :complete
    assert result.reservation == nil
    assert result.absence_at_ms != nil
    assert result.evidence == :exited
    assert {:ok, []} = Client.list(client)
    assert String.trim(kvm_descriptors) == ""

    %{
      command_exit: 0,
      fill: Jason.decode!(result.result.stdout),
      available_bytes_before_delete: 0,
      stop_requests: 0,
      inventory: []
    }
  else
    assert result.cleanup == :failed
    assert result.state == :unknown
    assert result.result == nil
    assert result.evidence != :termination_confirmed
    assert result.reservation != nil
    assert result.absence_at_ms == nil
    assert result.cancel_requested_at_ms != nil
    assert result.last_error.operation == :stop
    assert :persistent_term.get({SmolBox.DiscardProbeTransport, :stop_observed})

    assert :persistent_term.get({SmolBox.DiscardProbeTransport, :available_before_delete}, nil) ==
             nil

    assert {:ok, observed} = Client.inspect_machine(client, result.machine_name)
    assert SmolBox.Machine.same_incarnation?(result.created_machine, observed)
    assert observed.state == :running
    assert String.trim(kvm_descriptors) != ""
    assert System.system_time(:millisecond) < result.deadlines.execution + spec.retention_ms

    %{
      command_exit: nil,
      fill: :persistent_term.get({SmolBox.DiscardProbeTransport, :fill}),
      stop_failed: true,
      delete_requests: 0,
      machine_state: observed.state
    }
  end

report =
  Map.merge(report, %{
    status: "passed",
    runtime: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.16.0"),
    mode: mode,
    cleanup: result.cleanup,
    evidence: result.evidence,
    duplicate_submission: "same_execution",
    reservation_released: result.reservation == nil,
    absence_observed: result.absence_at_ms != nil,
    owned_kvm_descriptors: if(String.trim(kvm_descriptors) == "", do: "absent", else: "present")
  })

File.write!(report_path, Jason.encode!(report, pretty: true))
Supervisor.stop(runtime)
GenServer.stop(store)

# The unknown case deliberately leaves the VM for external candidate teardown.
# That teardown is never recorded as successful managed cleanup.
IO.puts("Managed storage #{mode}: expected cleanup and accounting observations verified")
