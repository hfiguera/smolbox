# Run with mix run in the disposable Linux guest, never on macOS.
defmodule SmolBox.CleanupRegression do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Client, Command, Error, Files, Identity, Machine, MachineSpec, Worker}
  @control Path.expand("cleanup-regression-control.sh", __DIR__)
  @data "/srv/smolbox-cleanup/data"
  @unit "smolbox-cleanup.service"
  @group "/sys/fs/cgroup/system.slice/#{@unit}"

  def run(version, label) do
    assert :os.type() == {:unix, :linux}
    assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
    assert version in ["1.14.1", "1.14.6"]
    assert Regex.match?(~r/\A[a-z0-9-]{1,40}\z/, label)
    path = "/home/lab/cleanup-validation/reports/#{label}.json"
    refute File.exists?(path)
    Process.put(:report, %{version: version, label: label, started_utc: DateTime.utc_now()})
    Process.put(:report_path, path)

    try do
      verify_controls()

      {:ok, worker} =
        Worker.new("cleanup-regression", "http://localhost",
          unix_socket: "/srv/smolbox-cleanup/run/api.sock",
          operation_timeout_ms: 60_000
        )

      {:ok, client} = Client.new(worker)
      health!(client, version)
      assert {:ok, []} = Client.list(client)
      created = create!(client)
      checkpoint(:created, Map.from_struct(created))
      assert {:ok, running} = Client.start(client, created.name)
      assert Machine.same_incarnation?(created, running)
      assert python!(client, created.name, "print('before-fill')").stdout == "before-fill\n"
      checkpoint(:before_fill, storage())
      verify_shared_storage!(created)

      source = """
      import os,json
      n=0
      error=None
      try:
          with open('/workspace/quota.bin','xb',buffering=0) as f:
              for i in range(640):
                  n+=f.write(b'x'*1048576)
                  os.fsync(f.fileno())
      except OSError as e: error={'errno':e.errno,'message':e.strerror}
      print(json.dumps({'written_bytes':n,'error':error}),flush=True)
      """

      fill = python!(client, created.name, source).stdout |> Jason.decode!()
      checkpoint(:fill, fill)
      checkpoint(:after_fill, storage())
      assert fill["error"]["errno"] in [5, 28]
      assert fill["written_bytes"] <= 640 * 1_048_576
      assert storage().available_bytes == 0, "The shared filesystem must actually be full"

      assert {:ok, observed} = Client.inspect_machine(client, created.name)
      assert Machine.same_incarnation?(created, observed)
      assert {:ok, stopped} = Client.stop(client, created.name)
      assert Machine.same_incarnation?(created, stopped)
      assert stopped.state == :stopped
      checkpoint(:after_stop, storage())
      # Stop may release one tmpfs block of runtime bookkeeping. Record it;
      # do not fill the remainder from the host or change the guest workload.
      assert storage().available_bytes <= 4096
      deletion = Client.delete(client, created.name)
      checkpoint(:delete, outcome(deletion))
      checkpoint(:after_delete, storage())
      checkpoint(:cgroup_after_delete, counters())

      if version == "1.14.1" do
        assert {:error, %Error{evidence: :dispatch_uncertain}} = deletion
        assert {:ok, retained} = Client.inspect_machine(client, created.name)
        assert Machine.same_incarnation?(created, retained)
        assert retained.state == :stopped
        assert storage().available_bytes <= 4096
        checkpoint(:baseline, "original failure reproduced; API cleanup did not succeed")
      else
        assert deletion == :ok
        absent!(client, created.name)
        assert storage().available_bytes > 128 * 1_048_576

        hash =
          :crypto.hash(:sha256, created.name) |> Base.encode16(case: :lower) |> binary_part(0, 16)

        {_, status} =
          System.cmd("sudo", ["test", "!", "-e", "#{@data}/.cache/smolvm/vms/#{hash}"])

        assert status == 0, "The VM's data directory must be absent"
        checkpoint(:data_directory_absent, true)

        {_, 0} = System.cmd("sudo", ["bash", @control, "restart"])
        health!(client, version)
        absent!(client, created.name)
        checkpoint(:absence_after_worker_restart, true)

        replacement = create!(client)
        checkpoint(:replacement, Map.from_struct(replacement))
        assert {:ok, running} = Client.start(client, replacement.name)
        assert Machine.same_incarnation?(replacement, running)
        input = "after-full-disk\n"

        assert :ok =
                 Client.upload(
                   client,
                   replacement.name,
                   "/workspace/input.txt",
                   input,
                   Files.sha256(input)
                 )

        result =
          python!(
            client,
            replacement.name,
            "from pathlib import Path; p=Path('/workspace'); (p/'output.txt').write_bytes((p/'input.txt').read_bytes()); print('replacement-ok')"
          )

        assert result.stdout == "replacement-ok\n"

        assert {:ok, ^input} =
                 Client.download(client, replacement.name, "/workspace/output.txt", 128)

        assert {:ok, observed} = Client.inspect_machine(client, replacement.name)
        assert Machine.same_incarnation?(replacement, observed)
        assert {:ok, stopped} = Client.stop(client, replacement.name)
        assert Machine.same_incarnation?(replacement, stopped)
        assert :ok = Client.delete(client, replacement.name)
        absent!(client, replacement.name)

        checkpoint(
          :subsequent_execution,
          "create/start/upload/exec/download/stop/delete/absence passed"
        )
      end

      checkpoint(:final_storage, storage())
      # The successful branch restarted the unit, which resets cgroup counters.
      checkpoint(:cgroup_final_worker, counters())
      checkpoint(:status, "passed")
    rescue
      error ->
        checkpoint(:status, "failed")
        checkpoint(:failure, Exception.message(error))
        reraise error, __STACKTRACE__
    after
      checkpoint(:finished_utc, DateTime.utc_now())
      IO.puts(Jason.encode!(Process.get(:report)))
    end
  end

  defp verify_controls do
    limits =
      Map.new(
        ["memory.max", "memory.swap.max", "cpu.max", "pids.max"],
        &{&1, File.read!("#{@group}/#{&1}") |> String.trim()}
      )

    assert limits == %{
             "memory.max" => "2147483648",
             "memory.swap.max" => "0",
             "cpu.max" => "200000 100000",
             "pids.max" => "128"
           }

    assert storage().total_bytes == 536_870_912
    checkpoint(:limits, limits)
    checkpoint(:cgroup_before, counters())
  end

  defp verify_shared_storage!(created) do
    hash =
      :crypto.hash(:sha256, created.name) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    paths = [
      @data,
      "#{@data}/.local/share/smolvm/server/smolvm.db",
      "#{@data}/.cache/smolvm/vms/#{hash}"
    ]

    {output, 0} = System.cmd("sudo", ["stat", "-c", "%d" | paths])
    assert output |> String.split() |> MapSet.new() |> MapSet.size() == 1
    checkpoint(:shared_filesystem, %{paths: paths, device_ids: String.split(output)})

    {fds, 0} =
      System.cmd("sudo", [
        "bash",
        "-c",
        "for pid in $(pgrep -u smolbox-cleanup); do readlink /proc/$pid/fd/* 2>/dev/null || true; done"
      ])

    assert String.contains?(fds, "kvm-vm")
    assert String.contains?(fds, "kvm-vcpu")
    checkpoint(:nested_kvm_descriptors, true)
  end

  defp health!(client, version, attempts \\ 50)
  defp health!(_client, _version, 0), do: flunk("Worker health deadline expired")

  defp health!(client, version, attempts) do
    case Client.health(client) do
      {:ok, %{version: ^version}} ->
        assert :ok = Client.readiness(client)

      _ ->
        Process.sleep(100)
        health!(client, version, attempts - 1)
    end
  end

  defp create!(client) do
    {:ok, name} = Identity.machine_name("cleanup")

    {:ok, spec} =
      MachineSpec.new(name, "/opt/smolbox/catalog/python.smolmachine",
        cpus: 1,
        memory_mb: 256,
        storage_gb: 20,
        overlay_gb: 10
      )

    assert {:ok, created} = Client.create(client, spec)
    created
  end

  defp python!(client, name, source) do
    {:ok, command} = Command.new(["python", "-u", "-c", source], timeout_secs: 45)
    assert {:ok, result} = Client.exec(client, name, command, max_output_bytes: 4096)
    assert result.exit_code == 0
    result
  end

  defp absent!(client, name) do
    assert {:error, %Error{category: :not_found}} = Client.inspect_machine(client, name)
    assert {:ok, []} = Client.list(client)
  end

  defp storage do
    {output, 0} = System.cmd("sudo", ["bash", @control, "metrics"])
    [size, total, free, available] = output |> String.split() |> Enum.map(&String.to_integer/1)

    %{
      total_bytes: size * total,
      used_bytes: size * (total - free),
      available_bytes: size * available
    }
  end

  defp counters do
    Map.new(
      ["memory.peak", "memory.events", "cpu.stat", "pids.peak", "pids.events"],
      &{&1, File.read!("#{@group}/#{&1}") |> String.trim()}
    )
  end

  defp outcome(:ok), do: %{status: "ok"}
  defp outcome({:error, error}), do: Map.take(error, [:category, :operation, :evidence, :message])

  defp checkpoint(key, value) do
    report = Map.put(Process.get(:report), key, value)
    Process.put(:report, report)
    path = Process.get(:report_path)
    File.write!(path <> ".part", Jason.encode!(report, pretty: true), [:sync])
    File.rename!(path <> ".part", path)
  end
end

[version, label] = System.argv()
SmolBox.CleanupRegression.run(version, label)
