# Controlled responders, only inside the disposable worker network namespace.
# Every test destination is reachable here; deny results must come from the VM policy.
true = :os.type() == {:unix, :linux}
{"smolbox-nested\n", 0} = System.cmd("hostname", [])

for address <- [{198, 18, 0, 10}, {198, 18, 0, 11}] do
  {:ok, listener} = :gen_tcp.listen(8088, [:binary, ip: address, active: false, reuseaddr: true])

  spawn_link(fn ->
    for _ <- 1..100 do
      {:ok, socket} = :gen_tcp.accept(listener, 300_000)
      :gen_tcp.send(socket, "fixture-ok\n")
      :gen_tcp.close(socket)
    end
  end)
end

{:ok, dns} = :gen_udp.open(53, [:binary, ip: {1, 1, 1, 1}, active: false])

parse_name = fn recurse, bytes, labels ->
  case bytes do
    <<0, rest::binary>> ->
      {Enum.reverse(labels) |> Enum.join("."), rest}

    <<size, label::binary-size(size), rest::binary>> when size in 1..63 ->
      recurse.(recurse, rest, [label | labels])
  end
end

for _ <- 1..300 do
  {:ok, {source, port, <<id::16, _flags::16, 1::16, _::48, question::binary>>}} =
    :gen_udp.recv(dns, 512, 300_000)

  {name, <<kind::16, 1::16>>} = parse_name.(parse_name, question, [])
  last = if name in ["allowed.smolbox.test", "sub.allowed.smolbox.test"], do: 10, else: 11

  answer =
    if kind == 1, do: <<192, 12, 1::16, 1::16, 30::32, 4::16, 198, 18, 0, last>>, else: <<>>

  count = if kind == 1, do: 1, else: 0

  :ok =
    :gen_udp.send(
      dns,
      source,
      port,
      <<id::16, 0x8180::16, 1::16, count::16, 0::32, question::binary, answer::binary>>
    )
end
