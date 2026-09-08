# Run through the durable example so these cases use the actual PostgreSQL store.
defmodule SmolBox.DurableCandidate do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{Client, Error, FaultTransport, Runtime}
  alias SmolBox.DurableHost.{Demo, Store}
  alias SmolBox.Example.Setup

  def run(kind) when kind in ["worker_oom", "database_outage", "worker_deadline"] do
    assert {"smolbox-nested\n", 0} = System.cmd("hostname", [])
    assert System.get_env("SMOLBOX_LINUX_CANDIDATE") == "true"
    command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "stop"])

    if kind == "worker_deadline",
      do:
        command([
          "bash",
          "/opt/smolbox/source/scripts/lab/candidate-control.sh",
          "deadline",
          "300"
        ])

    SmolBox.LabCandidate.reset()
    root = "/home/lab/qualification/durable-#{kind}-#{System.unique_integer([:positive])}"
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.mkdir!(root <> "/objects")
    File.chmod!(root <> "/objects", 0o700)

    for file <- ["fingerprint", "encryption"] do
      File.write!(root <> "/" <> file, :crypto.strong_rand_bytes(32))
      File.chmod!(root <> "/" <> file, 0o600)
    end

    settings = %{
      "url" => "http://localhost",
      "artifact_path" => System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
      "artifact_sha256" => System.fetch_env!("SMOLBOX_PYTHON_SHA256"),
      "artifact_root" => root <> "/objects",
      "id" => Path.basename(root),
      "partition" => Path.basename(root),
      "fingerprint_key_file" => root <> "/fingerprint",
      "encryption_key_file" => root <> "/encryption",
      "wait" => true
    }

    {options, spec, _objects, store} = Demo.configure(settings)
    spec = execution_spec(spec, kind)
    [worker] = options[:workers]
    ledger = root <> "/attempts"
    FaultTransport.configure(worker.client.worker.id, nil, ledger)

    worker = %{
      worker
      | profiles: [spec.profile],
        client: %{worker.client | transport: FaultTransport}
    }

    options = Keyword.put(options, :workers, [worker])
    {:ok, runtime} = Runtime.start_link(options)

    report =
      try do
        {:ok, handle} = SmolBox.submit(runtime, spec)
        running = Setup.wait_for(runtime, handle, &(&1.state == :running), 60_000)
        assert File.read!(ledger) == "exec\n"

        assert {:ok, "x"} =
                 Client.download(worker.client, running.machine_name, "/workspace/count", 10)

        fault(kind, runtime, handle)
        unknown = Setup.wait_for(runtime, handle, &(&1.state == :unknown), 60_000)
        assert unknown.reservation != nil
        assert unknown.result == nil
        Supervisor.stop(runtime)
        assert {:ok, saved} = Store.fetch(store, handle)
        assert saved.fingerprint == running.fingerprint
        assert saved.machine_name == running.machine_name

        # Exact owned deployment was stopped independently. Resetting its private
        # storage does not reset the durable execution record or command identity.
        SmolBox.LabCandidate.reset()
        {:ok, recovered} = Runtime.start_link(options)

        try do
          assert {:ok, ^handle} = SmolBox.submit(recovered, spec)
          :ok = SmolBox.reconcile(recovered, spec.scope, spec.id)

          cleaned =
            Setup.wait_for(
              recovered,
              handle,
              &(&1.cleanup == :complete and &1.reservation == nil)
            )

          assert cleaned.state == :unknown and cleaned.result == nil
          assert cleaned.machine_name == running.machine_name
          assert cleaned.fingerprint == running.fingerprint
          assert File.read!(ledger) == "exec\n"
          assert {:ok, %{slots: 0}} = Store.usage(store, worker.client.worker.id)
          assert {:ok, []} = Client.list(worker.client)

          %{
            scenario: kind,
            status: "passed",
            dispatches: 1,
            result: "unknown",
            reservation_retained_during_outage: true,
            cleanup: "verified_absent",
            identity_preserved: true
          }
        after
          Supervisor.stop(recovered)
        end
      after
        if Process.alive?(runtime), do: Supervisor.stop(runtime)
        command(["systemctl", "start", "postgresql@16-main.service"])
        command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "stop"])

        command([
          "bash",
          "/opt/smolbox/source/scripts/lab/candidate-control.sh",
          "deadline",
          "300"
        ])
      end

    File.write!(
      "/home/lab/qualification/durable-#{kind}.json",
      Jason.encode!(report, pretty: true)
    )

    IO.puts(Jason.encode!(report))
  end

  defp execution_spec(spec, kind) do
    seconds = if kind == "worker_deadline", do: 300, else: 30
    profile = %{spec.profile | id: "candidate-#{seconds}-seconds", execution_ms: seconds * 1000}
    spec = %{spec | profile: profile, command: %{spec.command | timeout_secs: seconds}}

    if kind == "worker_deadline" do
      # The real unit clock starts before boot and expires before this command's
      # own timeout. The readiness output makes running observable over SSE.
      source =
        "import pathlib,time; pathlib.Path('/workspace/count').write_text('x'); print('started',flush=True); time.sleep(300)"

      %{spec | command: %{spec.command | argv: ["python", "-u", "-c", source]}}
    else
      spec
    end
  end

  defp fault("worker_oom", _runtime, _handle) do
    {_output, status} =
      System.cmd(
        "sudo",
        ["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "fault", "memory"],
        stderr_to_stdout: true
      )

    assert status != 0
    command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "stop"])
    {result, 0} = System.cmd("sudo", ["cat", "/run/smolbox-qualification-evidence/result"])
    assert String.trim(result) == "oom-kill"
  end

  defp fault("database_outage", runtime, {scope, id}) do
    command(["systemctl", "stop", "postgresql@16-main.service"])
    assert {:error, %Error{category: :store}} = SmolBox.fetch(runtime, scope, id)
    command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "stop"])
    command(["systemctl", "start", "postgresql@16-main.service"])
  end

  defp fault("worker_deadline", _runtime, _handle) do
    # Observe the actual candidate deadline independently of the API/controller.
    # RuntimeMaxSec is not mutable through set-property on systemd 255.

    {result, 0} =
      System.cmd("timeout", [
        "310",
        "bash",
        "-c",
        "while systemctl is-active --quiet smolbox-qualification.service; do sleep 0.1; done; systemctl show smolbox-qualification.service -p Result --value"
      ])

    assert String.trim(result) == "timeout"

    command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "stop"])
    command(["bash", "/opt/smolbox/source/scripts/lab/candidate-control.sh", "deadline", "300"])
  end

  defp command(args) do
    assert {_, 0} = System.cmd("sudo", args, stderr_to_stdout: true)
  end
end

[scenario] = System.argv()
SmolBox.DurableCandidate.run(scenario)
