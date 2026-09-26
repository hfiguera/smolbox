# Run through ssh linux inside the disposable nested guest only.
import ExUnit.Assertions
alias SmolBox.{Client, Command, Machine, MachineSpec, NetworkPolicy, Worker}
assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
[mode] = System.argv()

network =
  case mode do
    "offline" ->
      :offline

    "cidr" ->
      {:ok, policy} = NetworkPolicy.new(cidrs: ["198.18.0.10/32"])
      policy

    "hosts" ->
      {:ok, policy} = NetworkPolicy.new(hosts: ["allowed.smolbox.test"])
      policy
  end

{:ok, worker} =
  Worker.new("network-lab", "http://localhost",
    unix_socket: "/srv/sbq/run/api.sock",
    receive_timeout_ms: 115_000,
    operation_timeout_ms: 150_000
  )

{:ok, client} = Client.new(worker)

{:ok, spec} =
  MachineSpec.new("network-#{mode}", "/opt/smolbox/catalog/python.smolmachine",
    network: network,
    memory_mb: 256
  )

assert {:ok, created} = Client.create(client, spec)
assert created.network == network

python = fn destinations ->
  """
  import socket, json
  result = {}
  for name, host in #{Jason.encode!(destinations)}:
      try:
          s = socket.create_connection((host, 8088), timeout=2)
          result[name] = s.recv(64).decode() == 'fixture-ok\\n'
          s.close()
      except OSError:
          result[name] = False
  print(json.dumps(result))
  """
end

destinations = [
  ["allowed_ip", "198.18.0.10"],
  ["blocked_ip", "198.18.0.11"],
  ["allowed_host", "allowed.smolbox.test"],
  ["allowed_subdomain", "sub.allowed.smolbox.test"],
  ["blocked_host", "blocked.smolbox.test"],
  ["suffix_attack", "notallowed.smolbox.test"]
]

try do
  assert {:ok, running} = Client.start(client, created.name)
  assert Machine.same_incarnation?(created, running)
  {:ok, command} = Command.new(["python", "-c", python.(destinations)], timeout_secs: 45)
  assert {:ok, %{exit_code: 0, stdout: output}} = Client.exec(client, created.name, command)
  result = Jason.decode!(output)

  expected =
    case mode do
      "offline" ->
        %{
          "allowed_ip" => false,
          "blocked_ip" => false,
          "allowed_host" => false,
          "allowed_subdomain" => false,
          "blocked_host" => false,
          "suffix_attack" => false
        }

      "cidr" ->
        %{
          "allowed_ip" => true,
          "blocked_ip" => false,
          "allowed_host" => false,
          "allowed_subdomain" => false,
          "blocked_host" => false,
          "suffix_attack" => false
        }

      "hosts" ->
        %{
          "allowed_ip" => false,
          "blocked_ip" => false,
          "allowed_host" => true,
          "allowed_subdomain" => true,
          "blocked_host" => false,
          "suffix_attack" => false
        }
    end

  assert result == expected
  assert {:ok, stopped} = Client.stop(client, created.name)
  assert Machine.same_incarnation?(created, stopped)
  assert {:ok, restarted} = Client.start(client, created.name)
  assert Machine.same_incarnation?(created, restarted)

  allowed = if mode == "hosts", do: "allowed.smolbox.test", else: "198.18.0.10"
  repeated = python.([["allowed", allowed], ["blocked", "198.18.0.11"]])
  {:ok, repeat} = Command.new(["python", "-c", repeated], timeout_secs: 15)

  assert {:ok, %{exit_code: 0, stdout: output}} = Client.exec(client, created.name, repeat)
  restart = Jason.decode!(output)
  assert restart == %{"allowed" => mode != "offline", "blocked" => false}

  File.write!(
    "/home/lab/qualification/network-#{mode}.json",
    Jason.encode!(
      %{
        status: "passed",
        mode: mode,
        observations: result,
        restart_observations: restart,
        policy_retained_after_restart: true,
        denied_after_restart: true,
        runtime: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.19.0")
      },
      pretty: true
    )
  )

  IO.puts("network #{mode}: policy and six probes passed, denial persists after restart")
after
  assert {:ok, _} = Client.stop(client, created.name)
  assert :ok = Client.delete(client, created.name)
  assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
end
