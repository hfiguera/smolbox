defmodule SmolBox.ClientRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Command,
    Error,
    Files,
    Identity,
    Machine,
    MachineSpec,
    Result,
    TestPeer,
    TestTLS,
    Worker
  }

  @moduletag :runtime
  @moduletag timeout: 120_000

  setup_all do
    url = System.fetch_env!("SMOLBOX_RUNTIME_URL")
    python = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")
    javascript = System.fetch_env!("SMOLBOX_JS_ARTIFACT")
    for artifact <- [python, javascript], do: assert(File.regular?(artifact))

    {:ok, worker} =
      Worker.new("qualification", url,
        allow_insecure_loopback: true,
        operation_timeout_ms: 20_000,
        receive_timeout_ms: 15_000
      )

    {:ok, client} = Client.new(worker)
    assert {:ok, _machines} = Client.list(client)
    %{client: client, python: python, javascript: javascript}
  end

  defp machine(client, artifact) do
    {:ok, name} = Identity.machine_name("sbxit")
    assert {:error, %Error{category: :not_found}} = Client.inspect_machine(client, name)
    {:ok, spec} = MachineSpec.new(name, artifact)
    assert {:ok, created} = Client.create(client, spec)
    on_exit(fn -> cleanup(client, created) end)
    assert {:ok, %Machine{state: :running} = running} = Client.start(client, name)
    assert Machine.same_incarnation?(created, running)
    name
  end

  defp cleanup(client, created) do
    case Client.inspect_machine(client, created.name) do
      {:error, %Error{category: :not_found}} ->
        :ok

      {:ok, observed} ->
        assert Machine.same_incarnation?(created, observed),
               "refusing cleanup of changed machine identity"

        assert {:ok, %Machine{state: :stopped}} = Client.stop(client, created.name)
        assert :ok = Client.delete(client, created.name)

        assert {:error, %Error{category: :not_found}} =
                 Client.inspect_machine(client, created.name)
    end
  end

  test "Python bytes, source staging, output collection and nonzero exit", context do
    name = machine(context.client, context.python)

    script = """
    import pathlib, sys
    data = pathlib.Path('/workspace/input.bin').read_bytes()
    pathlib.Path('/workspace/output.bin').write_bytes(data[::-1])
    sys.stdout.buffer.write(bytes([0, 255, 10]))
    sys.stderr.write('diagnostic')
    raise SystemExit(7)
    """

    bytes = <<0, 255, 5, 10>>

    assert :ok =
             Client.upload(
               context.client,
               name,
               "/workspace/main.py",
               script,
               Files.sha256(script)
             )

    assert :ok =
             Client.upload(
               context.client,
               name,
               "/workspace/input.bin",
               bytes,
               Files.sha256(bytes)
             )

    {:ok, command} = Command.new(["python", "/workspace/main.py"])

    assert {:ok,
            %Result{exit_code: 7, stdout: <<0, 255, 10>>, stderr: "diagnostic", encoding: :bytes}} =
             Client.exec(context.client, name, command)

    assert {:ok, <<10, 5, 255, 0>>} =
             Client.download(context.client, name, "/workspace/output.bin", 100)
  end

  test "JavaScript, streamed events, timeout and guest network denial", context do
    name = machine(context.client, context.javascript)

    script = """
    const fs = require('node:fs');
    const net = require('node:net');
    fs.writeFileSync('/workspace/js.bin', Buffer.from([255, 0, 42]));
    const socket = net.connect({host: '1.1.1.1', port: 443});
    socket.setTimeout(1000);
    socket.on('connect', () => process.exit(99));
    socket.on('timeout', () => { socket.destroy(); console.log('denied'); });
    socket.on('error', () => { console.log('denied'); });
    """

    assert :ok =
             Client.upload(
               context.client,
               name,
               "/workspace/main.js",
               script,
               Files.sha256(script)
             )

    {:ok, command} = Command.new(["node", "/workspace/main.js"])

    assert {:ok, %Result{exit_code: 0, stdout: "denied\n", encoding: :lossy_utf8}} =
             Client.exec_stream(context.client, name, command)

    assert {:ok, <<255, 0, 42>>} = Client.download(context.client, name, "/workspace/js.bin", 100)
    {:ok, timeout} = Command.new(["node", "-e", "setTimeout(() => {}, 60000)"], timeout_secs: 1)
    assert {:ok, %Result{exit_code: 124}} = Client.exec(context.client, name, timeout)
  end

  test "stop terminates a running VM independently of the stream observer", context do
    name = machine(context.client, context.python)

    {:ok, command} =
      Command.new(["python", "-u", "-c", "import time; print('started'); time.sleep(60)"],
        timeout_secs: 60
      )

    parent = self()

    observer =
      Task.async(fn ->
        Client.exec_stream(context.client, name, command,
          on_event: fn
            {:stdout, bytes} -> send(parent, {:started, bytes})
            _event -> :ok
          end
        )
      end)

    assert_receive {:started, bytes}, 10_000
    assert byte_size(bytes) > 0
    started = System.monotonic_time(:millisecond)
    assert {:ok, %Machine{state: :stopped}} = Client.stop(context.client, name)
    assert System.monotonic_time(:millisecond) - started < 10_000
    assert {:ok, %Machine{state: :stopped}} = Client.inspect_machine(context.client, name)
    # A killed VM supplies no guaranteed per-command exit receipt.
    case Task.yield(observer, 3000) || Task.shutdown(observer, :brutal_kill) do
      {:ok, {:ok, %Result{exit_code: code}}} -> assert is_integer(code)
      {:ok, {:error, %Error{evidence: :dispatch_uncertain}}} -> :ok
      nil -> :ok
    end
  end

  test "starting and file initialization never replay the user command", context do
    name = machine(context.client, context.python)
    marker = "/workspace/dispatch-count"
    assert {:error, _missing} = Client.download(context.client, name, marker, 100)

    {:ok, command} =
      Command.new(["python", "-c", "open('/workspace/dispatch-count','ab').write(b'x')"])

    assert {:ok, %Result{exit_code: 0}} = Client.exec(context.client, name, command)
    assert {:ok, %Machine{state: :stopped}} = Client.stop(context.client, name)
    assert {:ok, %Machine{state: :running}} = Client.start(context.client, name)
    assert {:ok, "x"} = Client.download(context.client, name, marker, 100)
  end

  test "an authenticated TLS proxy forwards real worker lifecycle and execution", context do
    dir = Path.join(System.tmp_dir!(), "sbx-proxy-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    certs = TestTLS.create(dir)
    base_url = context.client.worker.base_url

    port =
      TestPeer.start(&proxy(&1, base_url),
        scheme: :https,
        certfile: certs.cert,
        keyfile: certs.key
      )

    {:ok, worker} =
      Worker.new("proxy", "https://localhost:#{port}",
        token: "disposable-test-token",
        ca_cert_file: certs.ca
      )

    {:ok, protected} = Client.new(worker)
    name = machine(context.client, context.python)
    assert {:ok, %Machine{state: :running}} = Client.inspect_machine(protected, name)
    {:ok, command} = Command.new(["python", "-c", "print('protected')"])

    assert {:ok, %Result{stdout: "protected\n", exit_code: 0}} =
             Client.exec(protected, name, command)

    wrong = %{protected | worker: %{worker | token: "incorrect"}}
    assert {:error, %Error{category: :authentication}} = Client.exec(wrong, name, command)
  end

  # Disposable fixture proxy, not a production proxy implementation. Only tiny
  # qualification requests are forwarded; authorization is checked before I/O.
  defp proxy(conn, base_url) do
    if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer disposable-test-token"] do
      {:ok, body, conn} = TestPeer.body(conn)
      method = %{"GET" => :get, "POST" => :post}[conn.method]

      response =
        Req.request!(
          method: method,
          url: base_url <> conn.request_path,
          body: body,
          headers: [{"content-type", "application/json"}],
          raw: true,
          retry: false,
          redirect: false
        )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(response.status, response.body)
    else
      TestPeer.json(conn, %{}, 401)
    end
  end
end
