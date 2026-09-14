import ExUnit.Assertions
assert {:unix, :linux} = :os.type()
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])

for host <- [
      "198.18.0.10",
      "198.18.0.11",
      "2001:db8::10",
      "2001:db8::11",
      "fd00::10",
      "10.77.0.10",
      "169.254.169.254",
      "127.0.0.1",
      "::1"
    ] do
  {:ok, ip} = :inet.parse_address(String.to_charlist(host))
  family = if tuple_size(ip) == 8, do: :inet6, else: :inet
  assert {:ok, socket} = :gen_tcp.connect(ip, 8088, [family, :binary, active: false], 1000)
  assert {:ok, "fixture-ok\n"} = :gen_tcp.recv(socket, 0, 1000)
  :gen_tcp.close(socket)
  assert {:ok, socket} = :gen_udp.open(0, [family, :binary, active: false])
  :ok = :gen_udp.send(socket, ip, 8088, "probe")
  assert {:ok, {^ip, 8088, "fixture-ok\n"}} = :gen_udp.recv(socket, 64, 1000)
  :gen_udp.close(socket)
end

IO.puts("All nine synthetic IPv4/IPv6 TCP and UDP endpoints reachable from worker namespace")

# Both normal and alternate DNS addresses answer the name that guests must deny.
query =
  <<4217::16, 256::16, 1::16, 0::48, 7, "blocked", 7, "smolbox", 4, "test", 0, 1::16, 1::16>>

for ip <- [{1, 1, 1, 1}, {198, 18, 0, 11}] do
  {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
  :ok = :gen_udp.send(socket, ip, 53, query)

  assert {:ok, {^ip, 53, <<4217::16, _::16, 1::16, 1::16, _::binary>>}} =
           :gen_udp.recv(socket, 512, 1000)

  :gen_udp.close(socket)
  {:ok, socket} = :gen_tcp.connect(ip, 53, [:binary, active: false, packet: 2], 1000)
  :ok = :gen_tcp.send(socket, query)
  assert {:ok, <<4217::16, _::16, 1::16, 1::16, _::binary>>} = :gen_tcp.recv(socket, 0, 1000)
  :gen_tcp.close(socket)
end

IO.puts("Normal and alternate DNS positive controls passed over UDP and TCP")
