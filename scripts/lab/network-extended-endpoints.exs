# Synthetic destinations inside the disposable worker namespace, never real services.
{:unix, :linux} = :os.type()
{"smolbox-nested\n", 0} = System.cmd("hostname", [])

addresses = [
  "198.18.0.10",
  "198.18.0.11",
  "2001:db8::10",
  "2001:db8::11",
  "fd00::10",
  "10.77.0.10",
  "169.254.169.254",
  "127.0.0.1",
  "::1"
]

for host <- addresses do
  {:ok, ip} = :inet.parse_address(String.to_charlist(host))
  family = if tuple_size(ip) == 8, do: :inet6, else: :inet

  {:ok, listener} =
    :gen_tcp.listen(8088, [family, :binary, ip: ip, active: false, reuseaddr: true])

  spawn_link(fn ->
    for _ <- 1..200 do
      {:ok, socket} = :gen_tcp.accept(listener, 300_000)
      :gen_tcp.send(socket, "fixture-ok\n")
      :gen_tcp.close(socket)
    end
  end)

  {:ok, udp} = :gen_udp.open(8088, [family, :binary, ip: ip, active: false])

  spawn_link(fn ->
    for _ <- 1..200 do
      {:ok, {source, port, "probe"}} = :gen_udp.recv(udp, 64, 300_000)
      :ok = :gen_udp.send(udp, source, port, "fixture-ok\n")
    end
  end)
end

# Satisfy upstream's IPv6 reachability check locally. No external route exists.
{:ok, probe_ip} = :inet.parse_address(~c"2606:4700:4700::1111")
{:ok, probe} = :gen_tcp.listen(443, [:inet6, :binary, ip: probe_ip, active: false])

spawn_link(fn ->
  for _ <- 1..100 do
    {:ok, socket} = :gen_tcp.accept(probe, 300_000)
    :gen_tcp.close(socket)
  end
end)

{:ok, state} = Agent.start_link(fn -> %{} end)

Code.require_file("network-dns.exs", __DIR__)

reply = fn <<id::16, _::16, 1::16, _::48, question::binary>> ->
  {name, <<kind::16, 1::16>>} = SmolBox.Lab.NetworkDNS.question_name(question)

  count =
    Agent.get_and_update(state, fn data ->
      count = Map.get(data, {name, kind}, 0)
      {count, Map.put(data, {name, kind}, count + 1)}
    end)

  address =
    cond do
      name == "rebind.allowed.smolbox.test" and count > 0 ->
        "10.77.0.10"

      name == "loopback.allowed.smolbox.test" ->
        "127.0.0.1"

      name == "metadata.allowed.smolbox.test" ->
        "169.254.169.254"

      String.ends_with?(name, ".allowed.smolbox.test") or name == "allowed.smolbox.test" ->
        "198.18.0.10"

      true ->
        "198.18.0.11"
    end

  bytes =
    case kind do
      1 ->
        {:ok, ip} = :inet.parse_address(String.to_charlist(address))
        :erlang.list_to_binary(Tuple.to_list(ip))

      28 ->
        if name == "private6.allowed.smolbox.test",
          do: <<0xFD00::16, 0::96, 0x10::16>>,
          else: <<0x2001::16, 0xDB8::16, 0::80, 0x10::16>>

      _ ->
        <<>>
    end

  answer =
    if bytes == <<>>,
      do: <<>>,
      else: <<192, 12, kind::16, 1::16, 0::32, byte_size(bytes)::16, bytes::binary>>

  <<id::16, 0x8180::16, 1::16, if(answer == <<>>, do: 0, else: 1)::16, 0::32, question::binary,
    answer::binary>>
end

for address <- [{1, 1, 1, 1}, {198, 18, 0, 11}] do
  {:ok, dns} = :gen_udp.open(53, [:binary, ip: address, active: false])

  spawn_link(fn ->
    for _ <- 1..400 do
      {:ok, {source, port, query}} = :gen_udp.recv(dns, 512, 300_000)
      :ok = :gen_udp.send(dns, source, port, reply.(query))
    end
  end)

  {:ok, dns_tcp} = :gen_tcp.listen(53, [:binary, ip: address, active: false, packet: 2])

  spawn_link(fn ->
    for _ <- 1..100 do
      {:ok, socket} = :gen_tcp.accept(dns_tcp, 300_000)
      {:ok, query} = :gen_tcp.recv(socket, 0, 2000)
      :ok = :gen_tcp.send(socket, reply.(query))
      :gen_tcp.close(socket)
    end
  end)
end

Process.sleep(300_000)
