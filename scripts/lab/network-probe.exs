import ExUnit.Assertions

assert :os.type() == {:unix, :linux}
assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])

results =
  for {label, address, port} <- [
        {"public_https", {1, 1, 1, 1}, 443},
        {"host_ssh", {10, 0, 2, 2}, 22},
        {"host_management", {10, 0, 2, 2}, 22_460}
      ],
      into: %{} do
    result = :gen_tcp.connect(address, port, [:binary, active: false], 1500)

    case result do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        flunk("Unexpected outbound connection: #{label}")

      {:error, reason} ->
        {label, Atom.to_string(reason)}
    end
  end

{:ok, socket} = :gen_udp.open(0, [:binary, active: false])
query = <<1234::16, 256::16, 1::16, 0::16, 0::16, 0::16, 7, "example", 3, "org", 0, 1::16, 1::16>>
:ok = :gen_udp.send(socket, {10, 0, 2, 3}, 53, query)
assert {:error, :timeout} = :gen_udp.recv(socket, 4096, 1500)
:gen_udp.close(socket)
results = Map.merge(results, %{"slirp_dns" => "timeout", "status" => "passed"})
File.write!("/home/lab/network.json", Jason.encode!(results, pretty: true))

IO.puts(
  "Restricted outer-guest TCP and DNS probes passed; inbound management SSH remains usable."
)
