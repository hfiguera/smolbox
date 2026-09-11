# Actual hostile workloads run only inside the Linux qualification guest.
defmodule SmolBox.QualificationProbe do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Client, Command, Error, Files, Identity, Machine, MachineSpec, Worker}

  def run(kind) do
    assert :os.type() == {:unix, :linux}
    assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])

    {:ok, worker} =
      Worker.new("candidate", "http://localhost", unix_socket: "/srv/sbq/run/api.sock")

    {:ok, client} = Client.new(worker)
    version = System.get_env("SMOLBOX_RUNTIME_VERSION", "1.14.6")
    assert version in ["1.14.1", "1.14.6"]
    assert {:ok, %{version: ^version, total: 0}} = Client.health(client)
    {:ok, name} = Identity.machine_name("qual")
    artifact = if kind == "node", do: "node", else: "python"

    {:ok, spec} =
      MachineSpec.new(name, "/opt/smolbox/catalog/#{artifact}.smolmachine",
        cpus: 2,
        memory_mb: 256,
        storage_gb: if(kind == "geometry", do: 1, else: 20),
        overlay_gb: if(kind == "geometry", do: 1, else: 10)
      )

    assert {:ok, created} = Client.create(client, spec)
    started = System.monotonic_time(:millisecond)

    report = %{
      scenario: kind,
      runtime_version: version,
      machine: name,
      source: "qualification-probe.exs",
      before: metrics()
    }

    report =
      try do
        assert {:ok, running} = Client.start(client, name)
        assert Machine.same_incarnation?(created, running)

        {boundary, 0} =
          System.cmd("sudo", ["bash", "/opt/smolbox/source/scripts/lab/vm-boundary.sh"])

        data = probe(kind, client, name)

        Map.merge(report, %{
          status: "passed",
          observations: data,
          vm_boundary: boundary,
          after_workload: metrics()
        })
      rescue
        error ->
          Map.merge(report, %{
            status: "failed",
            error: Exception.message(error),
            after_workload: metrics()
          })
      end

    report =
      Map.merge(report, %{
        cleanup: cleanup(client, created),
        elapsed_ms: System.monotonic_time(:millisecond) - started
      })

    report =
      if report.cleanup == "verified_absent", do: report, else: Map.put(report, :status, "failed")

    File.write!("/home/lab/qualification/#{kind}.json", Jason.encode!(report, pretty: true))
    IO.puts(Jason.encode!(Map.take(report, [:scenario, :status, :cleanup, :elapsed_ms])))
    if report.status != "passed", do: System.halt(1)
  end

  defp metrics do
    {output, 0} =
      System.cmd("sudo", [
        "bash",
        "/opt/smolbox/source/scripts/lab/candidate-control.sh",
        "metrics"
      ])

    output
  end

  defp cleanup(client, created) do
    with {:ok, observed} <- Client.inspect_machine(client, created.name),
         true <- Machine.same_incarnation?(created, observed),
         {:ok, _stopped} <- Client.stop(client, created.name),
         :ok <- Client.delete(client, created.name),
         {:error, %Error{category: :not_found}} <- Client.inspect_machine(client, created.name),
         {:ok, []} <- Client.list(client) do
      "verified_absent"
    else
      other -> inspect(other)
    end
  end

  defp python(client, name, source, options \\ []) do
    {:ok, command} =
      Command.new(["python", "-u", "-c", source],
        timeout_secs: Keyword.get(options, :timeout, 30)
      )

    assert {:ok, result} = Client.exec(client, name, command)
    assert result.exit_code == 0, "exit=#{result.exit_code} stderr=#{result.stderr}"
    Jason.decode!(result.stdout)
  end

  defp probe("smoke", client, name) do
    python(
      client,
      name,
      "import json, platform; print(json.dumps({'system': platform.system()}))"
    )
  end

  defp probe("node", client, name) do
    {:ok, command} =
      Command.new(["node", "-e", "console.log(JSON.stringify({platform:process.platform}));"])

    assert {:ok, %{exit_code: 0, stdout: output}} = Client.exec(client, name, command)
    assert Jason.decode!(output) == %{"platform" => "linux"}
    %{node: "executed"}
  end

  defp probe("geometry", client, name) do
    data =
      python(client, name, """
      import json, os, pathlib
      fs=os.statvfs('/workspace')
      pathlib.Path('/workspace/geometry').write_bytes(b'roundtrip')
      print(json.dumps({'filesystem_bytes':fs.f_blocks*fs.f_frsize,'uid':os.getuid()}))
      """)

    key = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    directory = "/srv/sbq/cache/smolvm/vms/#{key}"

    {sizes, 0} =
      System.cmd("sudo", [
        "stat",
        "-c",
        "%s",
        "#{directory}/storage.raw",
        "#{directory}/overlay.raw"
      ])

    actual = sizes |> String.split() |> Enum.map(&String.to_integer/1)

    expected =
      if System.get_env("SMOLBOX_RUNTIME_VERSION", "1.14.6") == "1.14.6",
        do: [1_073_741_824, 1_073_741_824],
        else: [21_474_836_480, 10_737_418_240]

    assert actual == expected
    assert data["filesystem_bytes"] <= hd(expected)
    assert {:ok, "roundtrip"} = Client.download(client, name, "/workspace/geometry", 32)
    Map.put(data, "raw_disk_bytes", actual)
  end

  defp probe("memory", client, name) do
    data =
      python(client, name, """
      import json, subprocess, sys
      child = subprocess.run([sys.executable, '-c', 'x=[bytearray(1048576) for _ in range(384)]'], timeout=20)
      log = subprocess.run(['dmesg'], capture_output=True, text=True, timeout=3)
      lines = [line for line in log.stdout.splitlines() if 'Killed process' in line or 'Out of memory' in line][-6:]
      print(json.dumps({'returncode': child.returncode, 'oom_log': lines, 'dmesg_exit': log.returncode}))
      """)

    assert data["returncode"] == -9
    assert Enum.any?(data["oom_log"], &String.contains?(&1, "Killed process"))
    data
  end

  defp probe("cpu", client, name) do
    python(client, name, """
    import json, multiprocessing, time
    def burn():
        end=time.monotonic()+8
        while time.monotonic()<end: pass
    start=time.monotonic()
    children=[multiprocessing.Process(target=burn) for _ in range(4)]
    for child in children: child.start()
    for child in children: child.join()
    print(json.dumps({'seconds':time.monotonic()-start,'exit_codes':[c.exitcode for c in children]}))
    """)
  end

  defp probe("processes", client, name) do
    data =
      python(client, name, """
      import json, os, time
      children=[]
      failure=None
      for i in range(192):
          try:
              pid=os.fork()
              if pid==0:
                  time.sleep(5)
                  os._exit(0)
              children.append(pid)
          except OSError as error:
              failure=error.errno
              break
      for pid in children: os.waitpid(pid, 0)
      print(json.dumps({'children':len(children),'errno':failure}))
      """)

    assert data["children"] > 96
    data
  end

  defp probe("disk", client, name) do
    data =
      python(
        client,
        name,
        """
        import json, os
        written=0
        failure=None
        try:
            with open('/workspace/fill','wb',buffering=0) as f:
                for i in range(1024):
                    f.write(b'x'*1048576)
                    os.fsync(f.fileno())
                    written+=1048576
        except OSError as error: failure=error.errno
        print(json.dumps({'written':written,'errno':failure}))
        """,
        timeout: 25
      )

    assert data["errno"] in [5, 28]
    data
  end

  defp probe(kind, client, name) when kind in ["output", "slow_reader"] do
    {:ok, command} =
      Command.new(
        ["python", "-u", "-c", "import os; [os.write(1,b'x'*65536) for _ in range(2048)]"],
        timeout_secs: 20
      )

    client = %{client | worker: %{client.worker | operation_timeout_ms: 3000}}
    callback = if kind == "slow_reader", do: fn _event -> Process.sleep(10_000) end, else: nil

    result =
      Client.exec_stream(client, name, command, max_output_bytes: 65_536, on_event: callback)

    assert {:error, %Error{category: category, exit_code: nil}} = result
    assert category in [:output_limit, :transport]

    %{
      category: category,
      producer_upper_bound: 134_217_728,
      captured_limit: 65_536,
      completed_transfer: false
    }
  end

  defp probe("isolation", client, name) do
    data =
      python(client, name, """
      import json, os, pathlib, socket
      paths=['/etc/smolbox-qualification-canary','/srv/sbq/run/api.sock','/srv/sbq/control/smolvm/server/smolvm.db','/home/lab/.ssh/authorized_keys','/dev/kvm','/var/lib/smolbox-lab/home/id_ed25519']
      files={p:os.path.exists(p) for p in paths}
      endpoints={}
      for host,port in [('1.1.1.1',443),('10.0.2.2',22),('10.0.2.2',22460),('100.96.0.1',10081),('127.0.0.1',19470),('169.254.169.254',80)]:
          s=socket.socket(); s.settimeout(0.5)
          try: s.connect((host,port)); result='connected'
          except OSError as error: result=str(error.errno)
          finally: s.close()
          endpoints[f'{host}:{port}']=result
      vsock={}
      for port in [6000,6004,10081]:
          try:
              s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM); s.settimeout(0.5)
              try: s.connect((2,port)); result='connected'
              finally: s.close()
          except OSError as error: result=str(error.errno)
          vsock[str(port)]=result
      print(json.dumps({'uid':os.getuid(),'host_paths':files,'endpoints':endpoints,'vsock':vsock,'control_env_present':any(k.startswith(('SMOLVM_','XDG_')) for k in os.environ)}))
      """)

    assert Enum.all?(data["host_paths"], fn {_path, exists} -> exists == false end)
    assert Enum.all?(data["endpoints"], fn {_endpoint, result} -> result != "connected" end)
    assert Enum.all?(data["vsock"], fn {_port, result} -> result != "connected" end)
    assert data["control_env_present"] == false
    data
  end

  defp probe("files", client, name) do
    python(client, name, """
    import json, os, pathlib
    pathlib.Path('/tmp/guest-only').write_text('guest-only')
    os.symlink('/tmp/guest-only','/workspace/link')
    os.mkfifo('/workspace/fifo')
    print(json.dumps({'created':True}))
    """)

    assert {:ok, "guest-only"} = Client.download(client, name, "/workspace/link", 32)

    assert {:error, %Error{category: :validation}} =
             Client.download(client, name, "/workspace/../etc/passwd", 32)

    data = "replacement"
    assert :ok = Client.upload(client, name, "/workspace/link", data, Files.sha256(data))
    client = %{client | worker: %{client.worker | operation_timeout_ms: 1000}}

    assert {:error, %Error{category: :transport}} =
             Client.download(client, name, "/workspace/fifo", 32)

    %{
      symlink: "guest-only target readable; no workspace containment claim",
      fifo: "observation deadline; VM cleanup required"
    }
  end
end

[scenario] = System.argv()
SmolBox.QualificationProbe.run(scenario)
