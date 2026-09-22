defmodule SmolBox.PortsRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Command,
    Identity,
    Machine,
    MachineSpec,
    NetworkPolicy,
    PortMapping,
    Worker
  }

  @moduletag :runtime
  @moduletag timeout: 180_000

  setup_all do
    {:ok, worker} =
      Worker.new(
        "ports-qualification",
        System.fetch_env!("SMOLBOX_RUNTIME_URL"),
        SmolBox.LabCandidate.endpoint_options(
          allow_insecure_loopback: true,
          operation_timeout_ms: 60_000,
          receive_timeout_ms: 55_000
        )
      )

    {:ok, client} = Client.new(worker)
    assert {:ok, %{version: "1.17.0"}} = Client.health(client)
    %{client: client, artifact: System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")}
  end

  test "inbound TCP works with denied outbound and with an explicit outbound allowlist", c do
    allowed = System.fetch_env!("SMOLBOX_PORT_ALLOWED_IP")
    denied = System.fetch_env!("SMOLBOX_PORT_DENIED_IP")
    outbound_port = System.fetch_env!("SMOLBOX_PORT_OUTBOUND_PORT") |> String.to_integer()

    for address <- [allowed, denied] do
      assert {:ok, socket} =
               :gen_tcp.connect(
                 String.to_charlist(address),
                 outbound_port,
                 [:binary, active: false],
                 3000
               )

      :gen_tcp.close(socket)
    end

    {:ok, policy} = NetworkPolicy.new(cidrs: [allowed <> "/32"])

    for network <- [:offline, policy] do
      created = create(c, 28_732, network)

      try do
        assert {:ok, running} = Client.start(c.client, created.name)
        assert Machine.same_incarnation?(created, running)

        program = """
        import socket, subprocess, time, urllib.request, pathlib, json
        pathlib.Path('/workspace/ports.txt').write_text('mapped')
        log = open('/workspace/http.log', 'ab', buffering=0)
        subprocess.Popen(['python','-m','http.server','8000','--bind','0.0.0.0','--directory','/workspace'],
          stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
        for attempt in range(40):
            try:
                assert urllib.request.urlopen('http://127.0.0.1:8000/ports.txt',timeout=.1).read() == b'mapped'
                break
            except OSError: time.sleep(.05)
        else: raise RuntimeError('HTTP readiness failed')
        results=[]
        for addr in ['#{allowed}','#{denied}']:
            try:
                s=socket.create_connection((addr,#{outbound_port}),timeout=1);s.close();results.append(True)
            except OSError: results.append(False)
        print(json.dumps(results))
        """

        {:ok, command} = Command.new(["python", "-c", program], timeout_secs: 10)

        assert {:ok, %{exit_code: 0, stdout: output}} =
                 Client.exec(c.client, created.name, command)

        assert Jason.decode!(output) == [network != :offline, false]

        assert {:ok, %{status: 200, body: "mapped"}} =
                 Req.get("http://127.0.0.1:28732/ports.txt",
                   retry: false,
                   redirect: false,
                   decode_body: false
                 )

        bindings = listeners()
        assert "127.0.0.1:28732" in bindings
        assert Enum.all?(bindings, &(&1 in ["127.0.0.1:28732", "[::1]:28732"]))

        if "[::1]:28732" in bindings do
          assert {:ok, %{status: 200, body: "mapped"}} =
                   Req.get("http://[::1]:28732/ports.txt",
                     retry: false,
                     redirect: false,
                     decode_body: false
                   )
        end

        IO.puts(
          Jason.encode!(%{
            port_listener_addresses: bindings,
            outbound_allowed: network != :offline
          })
        )
      after
        cleanup(c.client, created)
      end
    end
  end

  defp listeners do
    case :os.type() do
      {:unix, :darwin} ->
        {output, 0} = System.cmd("lsof", ["-nP", "-iTCP:28732", "-sTCP:LISTEN", "-F", "n"])

        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "n"))
        |> Enum.map(&String.trim_leading(&1, "n"))

      {:unix, :linux} ->
        {output, 0} = System.cmd("ss", ["-H", "-lnt", "sport = :28732"])
        output |> String.split("\n", trim: true) |> Enum.map(&(String.split(&1) |> Enum.at(3)))
    end
  end

  test "unrelated host listeners prevent start and restart without changing mappings", c do
    created = create(c, 28_733, :offline)

    try do
      for phase <- [:initial, :restart] do
        if phase == :restart do
          assert {:ok, _} = Client.start(c.client, created.name)
          assert {:ok, _} = Client.stop(c.client, created.name)
        end

        {:ok, listener} = listen(28_733, System.monotonic_time(:millisecond) + 5000)

        try do
          assert {:error, %{category: :port_conflict, evidence: :dispatch_uncertain}} =
                   Client.start(c.client, created.name)

          assert {:ok, observed} = Client.inspect_machine(c.client, created.name)
          assert Machine.same_incarnation?(created, observed)
          refute observed.state == :running
        after
          :gen_tcp.close(listener)
        end
      end
    after
      cleanup(c.client, created)
    end
  end

  # A stopped observation can precede the worker process closing its listeners.
  # Require actual release before installing the unrelated host listener.
  defp listen(port, deadline) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false]) do
      {:error, :eaddrinuse} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          listen(port, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  defp create(c, port, network) do
    {:ok, name} = Identity.machine_name("ports")

    {:ok, spec} =
      MachineSpec.new(name, c.artifact,
        ports: [%PortMapping{host: port, guest: 8000}],
        network: network
      )

    assert {:ok, created} = Client.create(c.client, spec)
    assert created.ports == spec.ports and created.network == network
    created
  end

  defp cleanup(client, created) do
    assert {:ok, observed} = Client.inspect_machine(client, created.name)
    assert Machine.same_incarnation?(created, observed)
    assert :ok = Client.delete(client, created.name)
    assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
  end
end
