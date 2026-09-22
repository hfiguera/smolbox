# Destructive storage probe: run only in the disposable, constrained Linux lab.
# Direct deletion below is an explicit discard of this synthetic test machine;
# it is not a proposed fallback for managed cleanup or uncertain executions.
import ExUnit.Assertions
alias SmolBox.CI.Child
alias SmolBox.{Client, Command, Identity, Machine, MachineSpec, Worker}

assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
assert {"kvm\n", 0} = System.cmd("systemd-detect-virt", [])
version = System.fetch_env!("SMOLBOX_RUNTIME_VERSION")
assert version in ["1.16.0", "1.16.1", "1.17.0"]
path = "/home/lab/qualification/disk-stop-#{version}.json"
refute File.exists?(path)
socket = "/srv/sbq/run/api.sock"

{:ok, endpoint} =
  Worker.new("disk-stop", "http://localhost",
    unix_socket: socket,
    operation_timeout_ms: 60_000,
    receive_timeout_ms: 55_000
  )

{:ok, client} = Client.new(endpoint)
assert {:ok, %{version: ^version, total: 0}} = Client.health(client)
{:ok, name} = Identity.machine_name("diskstop")

{:ok, spec} =
  MachineSpec.new(name, "/opt/smolbox/catalog/python.smolmachine",
    cpus: 2,
    memory_mb: 256,
    storage_gb: 20,
    overlay_gb: 10
  )

assert {:ok, created} = Client.create(client, spec)
assert {:ok, running} = Client.start(client, name)
assert Machine.same_incarnation?(created, running)

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
      print(json.dumps({'written':written,'errno':failure}))
      """
    ],
    timeout_secs: 25
  )

assert {:ok, result} = Client.exec(client, name, command)
assert result.exit_code == 0
fill = Jason.decode!(result.stdout)
assert fill["errno"] in [5, 28]
assert {:ok, before_stop} = Client.inspect_machine(client, name)
assert Machine.same_incarnation?(created, before_stop)

{response, stop_runner} =
  Child.execute(
    [
      "curl",
      "--silent",
      "--show-error",
      "--unix-socket",
      socket,
      "--max-time",
      "20",
      "--max-filesize",
      "65536",
      "-X",
      "POST",
      "http://localhost/api/v1/machines/#{name}/stop",
      "-w",
      "\n%{http_code}"
    ],
    timeout: 25_000,
    output_limit: 65_536
  )

assert stop_runner.status == "passed"
[_, body, status] = Regex.run(~r/\A(.*)\n(\d{3})\z/s, response)
status = String.to_integer(status)
assert {:ok, after_stop} = Client.inspect_machine(client, name)
assert Machine.same_incarnation?(created, after_stop)

# Save the observation before checking expectations or discarding the test VM.
report = %{
  runtime_version: version,
  fill: fill,
  stop_http_status: status,
  stop_body: Jason.decode!(body),
  state_after_stop: after_stop.state,
  same_incarnation: true,
  direct_delete_is_diagnostic_only: true
}

File.write!(path, Jason.encode!(report, pretty: true))
assert status == if(version == "1.16.0", do: 200, else: 500)
assert after_stop.state == if(version == "1.16.0", do: :stopped, else: :running)
assert :ok = Client.delete(client, name)
assert {:ok, []} = Client.list(client)
report = Map.put(report, :diagnostic_discard_cleanup, "verified_absent")
File.write!(path, Jason.encode!(report, pretty: true))

IO.puts(
  Jason.encode!(
    Map.take(report, [
      :runtime_version,
      :stop_http_status,
      :state_after_stop,
      :diagnostic_discard_cleanup
    ])
  )
)
