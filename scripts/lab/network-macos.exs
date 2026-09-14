# Ordinary bounded compatibility checks; no adversarial or exhaustion payloads.
import ExUnit.Assertions
alias SmolBox.{Client, Command, Machine, MachineSpec, NetworkPolicy, Worker}
assert {:unix, :darwin} = :os.type()
root = System.fetch_env!("SMOLBOX_NETWORK_MAC_ROOT")
artifact = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")
{:ok, ips} = :inet.getaddrs(~c"example.com", :inet)
allowed_ip = hd(ips)
allowed = to_string(:inet.ntoa(allowed_ip))
# Establish both destinations are reachable before testing a guest denial.
for ip <- [allowed_ip, {1, 1, 1, 1}] do
  assert {:ok, s} = :gen_tcp.connect(ip, 443, [:binary, active: false], 3000)
  :gen_tcp.close(s)
end

{:ok, worker} =
  Worker.new("mac-network", "http://localhost",
    unix_socket: root <> "/api.sock",
    receive_timeout_ms: 115_000,
    operation_timeout_ms: 150_000
  )

{:ok, client} = Client.new(worker)
{:ok, cidr} = NetworkPolicy.new(cidrs: [allowed <> "/32"])
{:ok, host} = NetworkPolicy.new(hosts: ["example.com"])

for {mode, network} <- [{"offline", :offline}, {"cidr", cidr}, {"hosts", host}] do
  {:ok, spec} = MachineSpec.new("mac-network-#{mode}", artifact, memory_mb: 256, network: network)
  assert {:ok, created} = Client.create(client, spec)
  assert created.network == network

  try do
    assert {:ok, running} = Client.start(client, created.name)
    assert Machine.same_incarnation?(created, running)

    probe = """
    import socket,json
    r={}
    for name,address in [('allowed_ip','#{allowed}'),('blocked_ip','1.1.1.1'),('allowed_name','example.com'),('blocked_name','cloudflare-dns.com')]:
        try:
            s=socket.create_connection((address,443),timeout=2);s.close();r[name]=True
        except OSError: r[name]=False
    print(json.dumps(r))
    """

    {:ok, command} = Command.new(["python", "-c", probe], timeout_secs: 25)

    expected = %{
      "allowed_ip" => mode == "cidr",
      "blocked_ip" => false,
      "allowed_name" => mode == "hosts",
      "blocked_name" => false
    }

    observations =
      for phase <- ["initial", "restart"], into: %{} do
        if phase == "restart" do
          assert {:ok, _} = Client.stop(client, created.name)
          assert {:ok, restarted} = Client.start(client, created.name)
          assert Machine.same_incarnation?(created, restarted)
        end

        assert {:ok, %{exit_code: 0, stdout: output}} = Client.exec(client, created.name, command)
        result = Jason.decode!(output)
        # DNS learning in the first run permits the same IP after subsequent queries,
        # but a restart must begin with an empty learned-IP cache.
        assert result == expected
        {phase, result}
      end

    File.write!(
      root <> "/#{mode}.json",
      Jason.encode!(
        %{status: "passed", policy: mode, approved_ip: allowed, observations: observations},
        pretty: true
      )
    )
  after
    assert {:ok, _} = Client.stop(client, created.name)
    assert :ok = Client.delete(client, created.name)
    assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
  end
end

IO.puts(
  "macOS: offline, CIDR and hostname policies passed before and after restart; all machines deleted"
)
