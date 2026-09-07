defmodule SmolBox.SecurityRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{Client, Command, Error, Files, Identity, Machine, MachineSpec, Result, Worker}

  @moduletag :runtime
  @moduletag timeout: 60_000

  setup do
    {:ok, worker} =
      Worker.new("security-probe", System.fetch_env!("SMOLBOX_RUNTIME_URL"),
        allow_insecure_loopback: true
      )

    {:ok, client} = Client.new(worker)
    {:ok, name} = Identity.machine_name("sbxsecure")
    {:error, %Error{category: :not_found}} = Client.inspect_machine(client, name)

    {:ok, spec} =
      MachineSpec.new(name, System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
        storage_gb: 20,
        overlay_gb: 10
      )

    assert {:ok, created} = Client.create(client, spec)
    on_exit(fn -> cleanup(client, created) end)
    assert {:ok, %Machine{state: :running} = running} = Client.start(client, name)
    assert Machine.same_incarnation?(created, running)
    %{client: client, name: name}
  end

  test "finite excessive output preserves only the exit evidence actually received", context do
    {:ok, command} =
      Command.new([
        "python",
        "-c",
        "import sys; sys.stdout.write('x' * 8192); raise SystemExit(7)"
      ])

    assert {:error, %Error{category: :output_limit, evidence: :exited, exit_code: 7}} =
             Client.exec(context.client, context.name, command, max_output_bytes: 128)

    assert {:error,
            %Error{category: :output_limit, evidence: :dispatch_uncertain, exit_code: nil}} =
             Client.exec_stream(context.client, context.name, command, max_output_bytes: 128)

    assert {:ok, %Machine{state: :running}} =
             Client.inspect_machine(context.client, context.name)
  end

  test "file caps and packed-image symlinks retain their actual upstream semantics", context do
    run(context, """
    import pathlib, os
    pathlib.Path('/workspace/small').write_bytes(b'x' * 65537)
    pathlib.Path('/workspace/large').write_bytes(b'x' * 1048577)
    pathlib.Path('/tmp/sbx-sentinel').write_bytes(b'guest-only-sentinel')
    os.symlink('/tmp/sbx-sentinel', '/workspace/link')
    """)

    assert {:error, %Error{category: :output_limit}} =
             Client.download(context.client, context.name, "/workspace/small", 65_536)

    # The worker must be configured with SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576.
    # Its HTTP error is deliberately not interpreted as a partial file result.
    assert {:error, %Error{category: :protocol}} =
             Client.download(context.client, context.name, "/workspace/large", 1_048_576)

    assert_worker_file_cap(context)

    # Pinned packed artifacts follow this guest symlink on read. This is an
    # observed limitation, not a workspace-containment security assertion.
    assert {:ok, "guest-only-sentinel"} =
             Client.download(context.client, context.name, "/workspace/link", 100)

    assert :ok =
             Client.upload(
               context.client,
               context.name,
               "/workspace/link",
               "changed",
               Files.sha256("changed")
             )

    assert {:ok, "changed"} =
             Client.download(context.client, context.name, "/workspace/link", 100)

    run(context, """
    import pathlib
    assert pathlib.Path('/tmp/sbx-sentinel').read_bytes() == b'guest-only-sentinel'
    assert not pathlib.Path('/workspace/link').is_symlink()
    """)
  end

  test "a blocked stream callback expires without claiming guest termination", context do
    source = """
    import os, pathlib, time
    print('started', flush=True)
    time.sleep(0.05)
    for _ in range(64):
        os.write(1, b'x' * 8192)
        time.sleep(0.01)
    pathlib.Path('/workspace/count').write_bytes(b'x')
    """

    {:ok, command} = Command.new(["python", "-u", "-c", source], timeout_secs: 10)
    bounded = %{context.client | worker: %{context.client.worker | operation_timeout_ms: 3000}}
    parent = self()

    observer =
      Task.async(fn ->
        Client.exec_stream(bounded, context.name, command,
          on_event: fn _event ->
            send(parent, {:blocked_callback, self()})

            receive do
              :release -> :ok
            end
          end
        )
      end)

    assert_receive {:blocked_callback, callback}, 5000
    monitor = Process.monitor(callback)

    assert {:error, %Error{category: :transport, evidence: :dispatch_uncertain, exit_code: nil}} =
             Task.await(observer, 5000)

    assert_receive {:DOWN, ^monitor, :process, ^callback, _reason}, 1000

    assert {:ok, %Machine{state: :running}} =
             Client.inspect_machine(context.client, context.name)

    assert {:ok, "x"} = Client.download(context.client, context.name, "/workspace/count", 1)
  end

  test "offline packed guests cannot reach the tested host control endpoints", context do
    port = URI.new!(context.client.worker.base_url).port

    result =
      run(context, """
      import http.client, json, os
      blocked = []
      for host, port, path in [('100.96.0.1',#{port},'/health'),
                               ('100.96.0.1',10081,'/api/v1/machines'),
                               ('127.0.0.1',#{port},'/health')]:
          conn = http.client.HTTPConnection(host, port, timeout=1)
          try:
              conn.request('GET', path)
              response = conn.getresponse()
              response.read(4097)
              blocked.append(False)
          except (OSError, http.client.HTTPException):
              blocked.append(True)
          finally:
              conn.close()
      token = any('ROLLOUT' in key and 'TOKEN' in key for key in os.environ)
      print(json.dumps({'blocked': blocked, 'rollout_token_present': token}))
      """)

    assert Jason.decode!(result.stdout) == %{
             "blocked" => [true, true, true],
             "rollout_token_present" => false
           }
  end

  test "a guest FIFO cannot keep the client alive beyond its operation deadline", context do
    run(context, "import os; os.mkfifo('/workspace/fifo')")
    bounded = %{context.client | worker: %{context.client.worker | operation_timeout_ms: 2000}}
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{category: :transport}} =
             Client.download(bounded, context.name, "/workspace/fifo", 100)

    assert System.monotonic_time(:millisecond) - started < 5000
    # The selected agent opens before checking file type; a FIFO can block that
    # guest I/O path. Stop the owned VM; the HTTP deadline is not cancellation.
    assert {:ok, %Machine{state: :stopped}} = Client.stop(context.client, context.name)
  end

  defp run(context, source) do
    {:ok, command} = Command.new(["python", "-u", "-c", source], timeout_secs: 15)

    assert {:ok, %Result{exit_code: 0} = result} =
             Client.exec(context.client, context.name, command)

    result
  end

  defp assert_worker_file_cap(context) do
    # Inspect a bounded error body so a different HTTP failure cannot satisfy
    # the server-limit fixture. Ordinary callers use the redacted Client error.
    response =
      Req.get!(
        context.client.worker.base_url <>
          "/api/v1/machines/#{context.name}/files/workspace/large",
        raw: true,
        retry: false,
        redirect: false,
        compressed: false,
        receive_timeout: 3000,
        into: fn {:data, bytes}, {request, response} ->
          body = (response.body || "") <> bytes
          assert byte_size(body) <= 4096
          {:cont, {request, %{response | body: body}}}
        end
      )

    assert response.status == 500
    assert %{"code" => "INTERNAL_ERROR", "error" => message} = Jason.decode!(response.body)
    assert message =~ "exceeding the 1048576 byte cap"
  end

  defp cleanup(client, created) do
    case Client.inspect_machine(client, created.name) do
      {:error, %Error{category: :not_found}} ->
        :ok

      {:ok, observed} ->
        assert Machine.same_incarnation?(created, observed)
        assert {:ok, %Machine{state: :stopped}} = Client.stop(client, created.name)
        assert :ok = Client.delete(client, created.name)

        assert {:error, %Error{category: :not_found}} =
                 Client.inspect_machine(client, created.name)
    end
  end
end
