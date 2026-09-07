defmodule SmolBox.CI.WorkerFault do
  @moduledoc false
  alias SmolBox.CI.{Child, HTTP, Util}
  @root Path.expand("../../..", __DIR__)

  def run(arguments) do
    {options, []} =
      Util.options!(
        arguments,
        [smolvm: :string, url: :string, python: :string, report: :string, scenario: :string],
        [:smolvm, :url, :python, :report]
      )

    scenario = options[:scenario] || "restart"
    Util.ensure!(scenario in ~w(restart unavailable missing), "unsupported fault scenario")
    uri = URI.parse(options[:url])

    Util.ensure!(
      Regex.match?(~r/\Ahttp:\/\/127\.0\.0\.1:[0-9]{1,5}\z/, options[:url]) and
        uri.port in 1..65_535,
      "fault fixture requires explicit loopback address"
    )

    Util.ensure!(!File.exists?(options[:report]), "fault report must be new")

    Util.ensure!(
      Util.command!([options[:smolvm], "--version"]) == "smolvm 1.14.1\n",
      "wrong worker version"
    )

    unused_port!(uri.port)

    if Util.platform() == "linux",
      do:
        Util.ensure!(
          System.get_env("SMOLVM_DATA_DIR") not in [nil, ""],
          "Linux fault fixture requires dedicated SMOLVM_DATA_DIR"
        )

    settings = settings(options, scenario)

    {:ok, state} =
      Agent.start_link(fn ->
        %{
          worker: nil,
          controller: nil,
          snapshots: [],
          settings: settings,
          worker_args: [options[:smolvm], "serve", "start", "-l", "127.0.0.1:#{uri.port}"]
        }
      end)

    report =
      try do
        exercise(state)
      rescue
        error -> %{status: "failed", failure: inspect(error.__struct__)}
      end

    cleanup_errors = cleanup(state)
    Agent.stop(state)

    report =
      Map.merge(report, %{
        scenario: scenario,
        retained_workspace: settings["workspace"],
        partition: settings["partition"]
      })

    report =
      if cleanup_errors == [],
        do: report,
        else: Map.merge(report, %{status: "failed", cleanup_errors: cleanup_errors})

    Util.write_json!(options[:report], report)
    IO.puts(JSON.encode!(report))

    Util.ensure!(
      report.status == "passed",
      "worker fault qualification failed; inspect retained report"
    )
  end

  defp unused_port!(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        raise ArgumentError, "listen port occupied; existing servers are never stopped"

      {:error, :econnrefused} ->
        :ok

      _ ->
        raise ArgumentError, "cannot establish unused fixture port"
    end
  end

  defp settings(options, scenario) do
    workspace = Util.temporary("sbx-worker-restart")
    File.mkdir!(Path.join(workspace, "objects"))
    File.chmod!(Path.join(workspace, "objects"), 0o700)

    for name <- ~w(fingerprint.key encryption.key) do
      file = Path.join(workspace, name)
      File.write!(file, :crypto.strong_rand_bytes(32), [:exclusive])
      File.chmod!(file, 0o600)
    end

    identity = "restart-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    settings = %{
      "url" => options[:url],
      "artifact_path" => Path.expand(options[:python]),
      "artifact_sha256" => Util.digest(options[:python]),
      "artifact_root" => Path.join(workspace, "objects"),
      "fingerprint_key_file" => Path.join(workspace, "fingerprint.key"),
      "encryption_key_file" => Path.join(workspace, "encryption.key"),
      "partition" => identity,
      "id" => identity,
      "wait" => true,
      "scenario" => scenario,
      "ledger" => Path.join(workspace, "dispatch-attempts")
    }

    file = Path.join(workspace, "settings.json")
    Util.write_json!(file, settings)
    File.chmod!(file, 0o600)
    Map.merge(settings, %{"file" => file, "workspace" => workspace})
  end

  defp start_worker(state) do
    args = Agent.get(state, & &1.worker_args)

    {:ok, worker} =
      Child.start_link(args,
        env: [{"SMOLVM_FILE_TRANSFER_MAX_BYTES", "1048576"}],
        timeout: 600_000
      )

    Agent.update(state, &%{&1 | worker: worker})
    url = Agent.get(state, & &1.settings["url"])
    ready!(url, System.monotonic_time(:millisecond) + 10_000)
    worker
  end

  defp ready!(url, deadline) do
    ready =
      try do
        HTTP.json!(url <> "/health")["version"] == "1.14.1"
      rescue
        ArgumentError -> false
      end

    if !ready do
      Util.ensure!(
        System.monotonic_time(:millisecond) < deadline,
        "owned worker readiness deadline elapsed"
      )

      Process.sleep(50)
      ready!(url, deadline)
    end
  end

  defp exercise(state) do
    settings = Agent.get(state, & &1.settings)
    url = settings["url"]
    started = System.monotonic_time(:millisecond)
    worker = start_worker(state)
    empty!(url)

    {:ok, controller} =
      Child.start_link(["mix", "run", "scripts/worker_restart.exs", settings["file"]],
        cd: Path.join(@root, "examples/durable_host"),
        phases: true,
        timeout: 600_000
      )

    Agent.update(state, &%{&1 | controller: controller})
    phase!(state, "phase:running")
    [created] = Agent.get(state, & &1.snapshots)
    stop_child(worker)
    Agent.update(state, &%{&1 | worker: nil})
    down_at = System.monotonic_time(:millisecond)
    true = Child.send_line(controller, "worker_down")
    phase!(state, "phase:paused", 140_000)
    outage = (System.monotonic_time(:millisecond) - down_at) / 1_000
    start_worker(state)

    machine_url =
      url <> "/api/v1/machines/" <> URI.encode(created["name"], &URI.char_unreserved?/1)

    observed = HTTP.json!(machine_url)

    Util.ensure!(
      same_machine?(observed, created) and observed["state"] == "running",
      "guest did not survive server outage"
    )

    Util.ensure!(
      HTTP.request(machine_url <> "/files/workspace/count") == {200, "x"},
      "guest marker differs"
    )

    if settings["scenario"] == "missing", do: delete_owned!(machine_url, created)
    true = Child.send_line(controller, "resume")

    if settings["scenario"] == "unavailable" do
      phase!(state, "phase:retained")
      retained = HTTP.json!(machine_url)

      Util.ensure!(
        same_machine?(retained, created) and retained["state"] == "running",
        "retained machine differs"
      )

      delete_owned!(machine_url, created)
      true = Child.send_line(controller, "resolved")
    end

    "phase:complete:" <> result = phase!(state, "phase:complete", 120_000)
    {_, report} = Child.await(controller)
    Util.ensure!(report.status == "passed", "controller did not exit successfully")
    Util.ensure!(File.read!(settings["ledger"]) == "exec\n", "command dispatch count differs")
    empty!(url)

    %{
      status: "passed",
      seconds: (System.monotonic_time(:millisecond) - started) / 1_000,
      result: JSON.decode!(result),
      dispatch_attempts: 1,
      guest_marker: "single byte before recovery",
      guest_survived_api_server: true,
      artifact_sha256: settings["artifact_sha256"],
      runtime_version: "1.14.1",
      platform: Util.platform(),
      outage_seconds: outage,
      operator_deleted_vm: settings["scenario"] != "restart"
    }
  end

  defp phase!(state, expected, timeout \\ 30_000) do
    wait_phase(state, expected, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_phase(state, expected, deadline) do
    Util.ensure!(
      System.monotonic_time(:millisecond) < deadline,
      "controller phase deadline elapsed"
    )

    controller = Agent.get(state, & &1.controller)

    case Child.next_phase(controller) do
      {:ok, line} ->
        record_assignment(state, line)

        if line == expected or String.starts_with?(line, expected <> ":"),
          do: line,
          else: wait_phase(state, expected, deadline)

      :empty ->
        Process.sleep(50)
        wait_phase(state, expected, deadline)

      :done ->
        raise ArgumentError, "controller exited before required phase"
    end
  end

  defp record_assignment(state, "phase:assigned:" <> data) do
    Agent.update(state, &%{&1 | snapshots: &1.snapshots ++ [JSON.decode!(data)]})
  end

  defp record_assignment(_, _), do: :ok

  defp same_machine?(observed, created) do
    expected = %{
      "name" => created["name"],
      "createdAt" => created["created_at"],
      "cpus" => created["cpus"],
      "memoryMb" => created["memory_mb"],
      "storageGb" => created["storage_gb"],
      "overlayGb" => created["overlay_gb"],
      "network" => false,
      "mounts" => [],
      "ports" => [],
      "gpu" => false,
      "cuda" => false
    }

    Enum.all?(expected, fn {key, value} -> observed[key] == value end)
  end

  defp delete_owned!(url, created) do
    case HTTP.request(url) do
      {404, _} ->
        :ok

      {200, bytes} ->
        current = JSON.decode!(bytes)

        Util.ensure!(
          same_machine?(current, created),
          "cleanup identity conflict; resource retained"
        )

        if current["state"] == "running", do: HTTP.json!(url <> "/stop", "POST", %{})
        stopped = HTTP.json!(url)

        Util.ensure!(
          same_machine?(stopped, created) and stopped["state"] != "running",
          "stop not verified"
        )

        HTTP.json!(url, "DELETE")
        Util.ensure!(elem(HTTP.request(url), 0) == 404, "owned VM still present after deletion")

      _ ->
        raise ArgumentError, "cannot establish cleanup identity"
    end
  end

  defp empty!(url),
    do:
      Util.ensure!(
        HTTP.json!(url <> "/api/v1/machines") == %{"machines" => []},
        "worker inventory not empty"
      )

  defp stop_child(nil), do: :ok

  defp stop_child(child) do
    Child.stop(child)
    GenServer.stop(child)
  end

  defp cleanup(state) do
    controller_errors = attempt(fn -> stop_child(Agent.get(state, & &1.controller)) end)

    machine_errors = attempt(fn -> cleanup_machines(state) end)

    worker_errors = attempt(fn -> stop_child(Agent.get(state, & &1.worker)) end)
    controller_errors ++ machine_errors ++ worker_errors
  end

  defp cleanup_machines(state) do
    snapshot = Agent.get(state, & &1)

    if snapshot.snapshots != [] do
      if is_nil(snapshot.worker) or elem(Child.snapshot(snapshot.worker), 1).exit_code != nil,
        do: start_worker(state)

      Enum.each(snapshot.snapshots, fn created ->
        url =
          snapshot.settings["url"] <>
            "/api/v1/machines/" <>
            URI.encode(created["name"], &URI.char_unreserved?/1)

        delete_owned!(url, created)
      end)
    end
  end

  defp attempt(fun) do
    fun.()
    []
  rescue
    error -> [inspect(error.__struct__)]
  catch
    :exit, _ -> ["child_unavailable"]
  end
end
