# Bounded adversarial probes only in the disposable nested guest.
import ExUnit.Assertions
alias SmolBox.{Client, Command, Machine, MachineSpec, NetworkPolicy, Worker}
assert {:unix, :linux} = :os.type()
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
[mode] = System.argv()

policy =
  case mode do
    "offline" ->
      :offline

    "cidr4" ->
      {:ok, p} = NetworkPolicy.new(cidrs: ["198.18.0.10/32"])
      p

    "cidr6" ->
      {:ok, p} = NetworkPolicy.new(cidrs: ["2001:db8::10/128"])
      p

    other when other in ["hosts", "strict"] ->
      {:ok, p} = NetworkPolicy.new(hosts: ["allowed.smolbox.test"])
      p
  end

{:ok, worker} =
  Worker.new("extended", "http://localhost",
    unix_socket: "/srv/sbq/run/api.sock",
    receive_timeout_ms: 115_000,
    operation_timeout_ms: 150_000
  )

{:ok, client} = Client.new(worker)

{:ok, spec} =
  MachineSpec.new("extended-#{mode}", "/opt/smolbox/catalog/python.smolmachine",
    network: policy,
    memory_mb: 256
  )

{:ok, created} = Client.create(client, spec)

probe = ~S"""
import socket,json,struct,http.client
r={}
def connect(host, udp=False):
    try:
        family=socket.AF_INET6 if ':' in host else socket.AF_INET
        s=socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        s.settimeout(0.8)
        s.connect((host,8088))
        if udp: s.send(b'probe')
        ok=s.recv(64)==b'fixture-ok\n'
        s.close()
        return ok
    except OSError: return False
for label,host in [('v4_allow','198.18.0.10'),('v4_deny','198.18.0.11'),('v6_allow','2001:db8::10'),('v6_deny','2001:db8::11'),('mapped_allow','::ffff:198.18.0.10'),('mapped_deny','::ffff:198.18.0.11'),('control','10.77.0.10'),('metadata','169.254.169.254'),('private6','fd00::10'),('mapped_control','::ffff:10.77.0.10'),('mapped_metadata','::ffff:169.254.169.254')]:
    for udp in [False,True]: r[label+('_udp' if udp else '_tcp')]=connect(host,udp)
# DNS through the guest gateway, with UDP and TCP transports and an alternate resolver address.
resolver=open('/etc/resolv.conf').read().split('nameserver ')[-1].split()[0]
def dns(name,kind=1,tcp=False,server=None):
    query=struct.pack('!6H',4217,256,1,0,0,0)+b''.join(bytes([len(p)])+p.encode() for p in name.split('.'))+b'\0'+struct.pack('!HH',kind,1)
    try:
        s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM);s.settimeout(0.8);s.connect((server or resolver,53))
        s.send((struct.pack('!H',len(query)) if tcp else b'')+query)
        data=s.recv(1024)
        if tcp: data=data[2:]
        s.close()
        if len(data)<12 or struct.unpack('!H',data[6:8])[0]==0:return None
        return socket.inet_ntop(socket.AF_INET6 if kind==28 else socket.AF_INET,data[-(16 if kind==28 else 4):])
    except OSError:return None
for label,name,tcp,server in [('dns_udp','allowed.smolbox.test',False,None),('dns_tcp','sub.allowed.smolbox.test',True,None),('dns_denied_udp','blocked.smolbox.test',False,None),('dns_denied_tcp','blocked.smolbox.test',True,None),('dns_alternate_denied','blocked.smolbox.test',False,'198.18.0.11'),('dns_suffix','allowed.smolbox.test.evil.test',False,None),('dns_alternate_tcp','blocked.smolbox.test',True,'198.18.0.11')]:
    r[label]=dns(name,tcp=tcp,server=server)
r['dns_aaaa']=dns('allowed.smolbox.test',28)
r['gateway_tcp']=connect(resolver)
r['gateway_udp']=connect(resolver,True)
# smolvm exposes a separate authenticated rollout service through the gateway.
for label,path,headers in [('rollout_unauthenticated','/api/v1/rollout-executors/fixture/generate',{}),('rollout_invalid_token','/api/v1/rollout-executors/fixture/generate',{'Authorization':'Bearer synthetic-invalid'}),('management_route','/api/v1/machines',{})]:
    try:
        c=http.client.HTTPConnection(resolver,10081,timeout=0.8)
        c.request('POST' if label!='management_route' else 'GET',path,body='{}',headers=headers)
        r[label]=c.getresponse().status;c.close()
    except OSError:r[label]=None
r['dns_private6']=dns('private6.allowed.smolbox.test',28)
r['learned_private6_tcp']=connect('fd00::10');r['learned_private6_udp']=connect('fd00::10',True)
r['learned_v4_tcp']=connect('198.18.0.10');r['learned_v4_udp']=connect('198.18.0.10',True)
r['learned_v6_tcp']=connect('2001:db8::10');r['learned_v6_udp']=connect('2001:db8::10',True)
for label in ['rebind','rebind','loopback','metadata']:
    address=dns(label+'.allowed.smolbox.test')
    key=label+('_second' if label in r else '')
    r[key]={'address':address,'tcp':connect(address) if address else False,'udp':connect(address,True) if address else False}
print(json.dumps(r))
"""

try do
  {:ok, running} = Client.start(client, created.name)
  assert Machine.same_incarnation?(created, running)
  {:ok, command} = Command.new(["python", "-c", probe], timeout_secs: 75)
  assert {:ok, %{exit_code: 0, stdout: output}} = Client.exec(client, created.name, command)
  observations = Jason.decode!(output)

  File.write!(
    "/home/lab/qualification/network-extended-#{mode}.json",
    Jason.encode!(%{mode: mode, observations: observations}, pretty: true)
  )

  IO.puts(output)

  for transport <- ["tcp", "udp"] do
    assert observations["v4_allow_#{transport}"] == (mode == "cidr4")
    assert observations["mapped_allow_#{transport}"] == (mode == "cidr4")
    assert observations["gateway_#{transport}"] == false
    assert observations["v6_allow_#{transport}"] == (mode == "cidr6")

    for denied <- [
          "v4_deny",
          "v6_deny",
          "mapped_deny",
          "control",
          "metadata",
          "private6",
          "mapped_control",
          "mapped_metadata",
          "learned_private6"
        ] do
      assert observations["#{denied}_#{transport}"] == false
    end

    assert observations["learned_v4_#{transport}"] == mode in ["cidr4", "hosts", "strict"]
    assert observations["learned_v6_#{transport}"] == mode in ["cidr6", "hosts", "strict"]
  end

  for key <- [
        "dns_denied_udp",
        "dns_denied_tcp",
        "dns_alternate_denied",
        "dns_alternate_tcp",
        "dns_suffix"
      ],
      do: assert(is_nil(observations[key]))

  if mode in ["hosts", "strict"] do
    assert observations["dns_udp"] == "198.18.0.10"
    assert observations["dns_tcp"] == "198.18.0.10"
    assert observations["dns_aaaa"] == "2001:db8::10"
    assert observations["dns_private6"] == "fd00::10"
    assert observations["rebind"]["tcp"]
    assert observations["rebind_second"]["address"] == "10.77.0.10"
    assert observations["rebind_second"]["tcp"] == false

    for transport <- ["tcp", "udp"] do
      assert observations["rebind"][transport]
      assert observations["rebind_second"][transport] == false
      assert observations["loopback"][transport] == false
      assert observations["metadata"][transport] == false
    end
  end

  assert observations["rollout_unauthenticated"] == if(mode == "offline", do: nil, else: 401)
  assert observations["rollout_invalid_token"] == if(mode == "offline", do: nil, else: 401)
  assert observations["management_route"] == if(mode == "offline", do: nil, else: 404)
  {:ok, stopped} = Client.stop(client, created.name)
  assert Machine.same_incarnation?(created, stopped)
  {:ok, restarted} = Client.start(client, created.name)
  assert Machine.same_incarnation?(created, restarted)
  # Repeat address tests after restart, without depending on DNS fixture counters.
  restart_probe = probe |> String.split("# DNS through") |> hd()

  {:ok, repeat} =
    Command.new(["python", "-c", restart_probe <> "print(json.dumps(r))"], timeout_secs: 40)

  assert {:ok, %{exit_code: 0, stdout: repeated}} = Client.exec(client, created.name, repeat)
  restart = Jason.decode!(repeated)
  for {key, value} <- restart, do: assert(value == observations[key])

  File.write!(
    "/home/lab/qualification/network-extended-#{mode}.json",
    Jason.encode!(%{mode: mode, status: "passed", observations: observations, restart: restart},
      pretty: true
    )
  )

  IO.puts("Extended #{mode}: policy, TCP/UDP, IPv6, DNS and synthetic boundary probes passed")
after
  assert {:ok, _} = Client.stop(client, created.name)
  assert :ok = Client.delete(client, created.name)
  assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
end
