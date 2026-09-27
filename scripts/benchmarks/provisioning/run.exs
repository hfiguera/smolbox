# Run from examples/durable_host with mix run; see the accompanying README.
for file <- ["config.exs", "metrics.exs"], do: Code.require_file(file, __DIR__)

defmodule SmolBox.ProvisioningBenchmark do
  @moduledoc false
  alias SmolBox.{
    Branches,
    BranchSpec,
    Checkpoint,
    CheckpointCaptureSpec,
    CheckpointResult,
    Checkpoints,
    Client,
    ExportResult,
    Exports,
    ExportSpec,
    Machines,
    ManagedMachineSpec,
    Source
  }

  alias SmolBox.DurableHost.Store
  alias SmolBox.Example.Setup
  alias SmolBox.{ProvisioningConfig, ProvisioningMetrics}

  import SmolBox.DurableHost.PersistentSteps,
    only: [lifecycle: 3, wait_machine: 3, shell_command: 5]

  @prepare """
  set -eu
  mkdir -p /workspace/project
  awk 'BEGIN {for (i=0; i<1000000; i++) printf "%d,%d\\n", i%1000, (i*37)%10000}' > /workspace/project/events.csv
  gzip -n /workspace/project/events.csv
  gzip -dc /workspace/project/events.csv.gz > /dev/shm/events.csv
  awk -F, '{count[$1]++; total[$1]+=$2} END {for (id in count) printf "%d %d %.0f\\n", id, count[id], total[id]}' /dev/shm/events.csv > /dev/shm/stations.tsv
  rm /dev/shm/events.csv
  cp /dev/shm/stations.tsv /workspace/project/precomputed.tsv
  """
  @query "awk '$1 == 42 {print}' /dev/shm/stations.tsv"
  @disk_query "awk '$1 == 42 {print}' /workspace/project/precomputed.tsv"
  @expected "42 1000 5054000\n"

  def run(config, phase) do
    true = :os.type() == {:unix, :linux}
    {"none\n", 1} = System.cmd("systemd-detect-virt", [])
    results = config["root"] <> "/results/" <> config["partition"]
    File.mkdir_p!(results)
    # A started phase is never automatically retried after a lost outcome.
    File.write!(results <> "/" <> phase <> ".started", DateTime.to_iso8601(DateTime.utc_now()), [
      :exclusive
    ])

    c = ProvisioningConfig.start(config)

    try do
      execute(c, phase)
      File.write!(results <> "/" <> phase <> ".completed", "ok\n", [:exclusive])
    after
      Supervisor.stop(ProvisioningConfig)
    end
  end

  defp execute(c, "prepare") do
    {:ok, []} = Client.list(c.client)
    source = {"provisioning", "prepared-source"}
    timed(c, "prepare", "base", 0, fn -> create(c, source, c.seed, true) end)

    timed(c, "prepare", "workload", 0, fn -> shell_command(c, source, "prepare", @prepare, "") end)

    shell_command(c, source, "check", @query, @expected)

    timed(c, "prepare", "checkpoint", 0, fn ->
      {:ok, request} =
        CheckpointCaptureSpec.new(id: "dataset", policy: c.capture_policy, idle: true)

      {:ok, handle} = Checkpoints.capture(c.runtime, source, request)
      {:ok, %{state: :captured, result: result}} = Checkpoints.await(c.runtime, handle, 900_000)
      quiescent!(c)
      {:ok, m} = Machines.inspect(c.runtime, source)

      {:ok, %{state: :completed}} =
        Checkpoints.resolve(c.runtime, handle, m.version, quiesced: true)

      save(c, "checkpoint-result.json", Map.from_struct(result))
    end)

    timed(c, "prepare", "capture-source-delete", 0, fn -> delete(c, source) end)
    source = {"provisioning", "export-source"}
    timed(c, "prepare", "export-base", 0, fn -> create(c, source, c.artifact, false) end)

    timed(c, "prepare", "export-workload", 0, fn ->
      shell_command(c, source, "prepare", @prepare, "")
    end)

    timed(c, "prepare", "stop-for-export", 0, fn ->
      {:ok, _} = lifecycle(c.runtime, source, :stop)
      wait_machine(c.runtime, source, &(&1.state == :stopped and &1.operation == nil))
    end)

    timed(c, "prepare", "export", 0, fn ->
      {:ok, request} =
        ExportSpec.new(
          id: "dataset",
          tag: c.config["partition"],
          destination: c.export_destination
        )

      {:ok, handle} = Exports.submit(c.runtime, source, request)
      {:ok, %{state: :published, result: result}} = Exports.await(c.runtime, handle, 900_000)
      quiescent!(c)
      {:ok, m} = Machines.inspect(c.runtime, source)
      {:ok, %{state: :completed}} = Exports.resolve(c.runtime, handle, m.version, quiesced: true)
      save(c, "export-result.json", Map.from_struct(result))
    end)

    timed(c, "prepare", "source-delete", 0, fn -> delete(c, source) end)
    {:ok, []} = Client.list(c.client)
  end

  defp execute(c, "measure") do
    {:ok, []} = Client.list(c.client)
    {:ok, source} = Store.machine(c.store, :fetch, [{"provisioning", "prepared-source"}])
    %{state: :completed, result: capture} = source.captures["dataset"]
    {:ok, export_source} = Store.machine(c.store, :fetch, [{"provisioning", "export-source"}])
    %{state: :completed, result: exported} = export_source.exports["dataset"]

    {:ok, checkpoint} =
      CheckpointResult.approval(capture, id: "prepared", worker_path: capture.path)

    {:ok, registry} = ExportResult.source(exported, id: "prepared-export")
    Supervisor.stop(c.runtime)

    c =
      ProvisioningConfig.boot(%{
        c
        | worker: %{
            c.worker
            | checkpoints: [checkpoint | c.worker.checkpoints],
              sources: [registry]
          }
      })

    c =
      Map.merge(c, %{
        checkpoint: Checkpoint.artifact(checkpoint),
        exported: Source.artifact(registry)
      })

    samples = c.config["samples"]
    true = samples in 1..40

    for batch <- 0..div(samples, 5) do
      indices = Enum.filter(0..samples, &(div(&1, 5) == batch))
      if indices != [], do: batch(c, batch, indices)
    end

    {:ok, []} = Client.list(c.client)
    {:ok, usage} = Store.usage(c.store, "benchmark")
    save(c, "retained-usage.json", usage)
  end

  defp execute(c, "cleanup") do
    {:ok, []} = Client.list(c.client)
    quiescent!(c)
    true = vm_directories(c) == []

    for batch <- 0..div(c.config["samples"], 5) do
      {:ok, parent} = Machines.inspect(c.runtime, {"provisioning", "branch-source-#{batch}"})
      true = parent.state == :deleted

      close_children(c, parent)
    end

    source = {"provisioning", "prepared-source"}
    {:ok, m} = Machines.inspect(c.runtime, source)
    true = m.state == :deleted
    %{state: :completed, result: result} = m.captures["dataset"]
    true = Setup.digest_file(result.path) == result.sha256
    :ok = File.rm(result.path)

    {:ok, _} =
      Checkpoints.release(c.runtime, {elem(source, 0), elem(source, 1), "dataset"},
        artifacts_removed: true
      )

    {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0} = usage} =
      Store.usage(c.store, "benchmark")

    save(c, "final-usage.json", usage)
  end

  defp close_children(c, parent) do
    for id <- Map.keys(parent.branch_children) do
      {:ok, child} = Machines.inspect(c.runtime, {parent.scope, id})

      if child.branch.state != :closed do
        {:ok, _} =
          Branches.release_storage(c.runtime, {parent.scope, id}, backing_removed: true)
      end
    end
  end

  defp batch(c, batch, indices) do
    source = {"provisioning", "branch-source-#{batch}"}

    timed(c, "source-setup", "branch-and-reuse", batch, fn ->
      create(c, source, c.seed, true)
      shell_command(c, source, "prepare", @prepare, "")
      shell_command(c, source, "check", @query, @expected)
    end)

    for i <- indices do
      modes = ["fresh", "export", "checkpoint", "branch", "reuse"]
      {first, last} = Enum.split(modes, rem(i, length(modes)))
      for mode <- last ++ first, do: sample(c, source, mode, i)
    end

    timed(c, "source-cleanup", "branch-and-reuse", batch, fn ->
      delete(c, source)
      quiescent!(c)
      {:ok, parent} = Machines.inspect(c.runtime, source)
      # All backing generations belong to this dedicated host directory. Verify
      # that every source/child machine directory is gone before the assertion.
      true = vm_directories(c) == []

      for id <- Map.keys(parent.branch_children) do
        {:ok, _} = Branches.release_storage(c.runtime, {parent.scope, id}, backing_removed: true)
      end
    end)
  end

  defp sample(c, source, mode, i) do
    handle = if mode == "reuse", do: source, else: {"provisioning", "#{mode}-#{i}"}

    timed(c, "ready", mode, i, fn ->
      provision(c, source, handle, mode)
      if mode == "fresh", do: shell_command(c, handle, "prepare-#{i}", @prepare, "")
      # Disk check defines useful project readiness independently of RAM restore.
      shell_command(c, handle, "disk-#{i}", @disk_query, @expected)
    end)

    timed(c, "memory-ready", mode, i, fn ->
      if mode == "export" do
        shell_command(
          c,
          handle,
          "load-#{i}",
          "test ! -e /dev/shm/stations.tsv && cp /workspace/project/precomputed.tsv /dev/shm/stations.tsv",
          ""
        )
      end

      shell_command(c, handle, "memory-#{i}", @query, @expected)
    end)

    timed(c, "isolation", mode, i, fn ->
      if mode != "reuse" do
        shell_command(
          c,
          handle,
          "change-#{i}",
          "printf changed > /workspace/project/precomputed.tsv; printf changed > /dev/shm/stations.tsv",
          ""
        )

        shell_command(
          c,
          source,
          "unchanged-#{mode}-#{i}",
          @query <> "; " <> @disk_query,
          @expected <> @expected
        )
      end
    end)

    timed(c, "cleanup", mode, i, fn ->
      if mode != "reuse", do: delete(c, handle)

      if mode == "branch" do
        quiescent!(c)
        {:ok, _} = Branches.retire(c.runtime, handle, quiesced: true)
      end
    end)
  end

  defp provision(_c, _source, _handle, "reuse"), do: :ok

  defp provision(c, source, {_, id}, "branch") do
    {:ok, spec} = BranchSpec.new(id: id, policy: c.branch_policy, idle: true)
    {:ok, handle} = Branches.create(c.runtime, source, spec)
    {:ok, %{branch: %{state: :ready}}} = Branches.await(c.runtime, handle, 120_000)
  end

  defp provision(c, _source, handle, mode) do
    artifact =
      case mode do
        "fresh" -> c.artifact
        "export" -> c.exported
        "checkpoint" -> c.checkpoint
      end

    create(c, handle, artifact, false)
  end

  defp create(c, {scope, id} = handle, artifact, checkpointable) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: scope,
        id: id,
        artifact: artifact,
        profile: c.profile,
        checkpointable: checkpointable
      )

    {:ok, ^handle} = Machines.create(c.runtime, spec)
    wait_machine(c.runtime, handle, &(&1.state == :created and &1.operation == nil))
    {:ok, _} = lifecycle(c.runtime, handle, :start)
    wait_machine(c.runtime, handle, &(&1.state == :running and &1.operation == nil))
  end

  defp delete(c, handle) do
    {:ok, _} = lifecycle(c.runtime, handle, :delete)
    m = wait_machine(c.runtime, handle, &(&1.state == :deleted))
    {:error, %{category: :not_found}} = Client.inspect_machine(c.client, m.machine_name)
    true = m.operation == nil
    true = m.active_execution == nil
  end

  defp quiescent!(c), do: true = File.ls!(c.config["root"] <> "/scratch") == []

  defp vm_directories(c) do
    Path.wildcard(c.config["worker_data"] <> "/.cache/smolvm/vms/*")
    |> Enum.filter(&(File.dir?(&1) and Path.basename(&1) not in ["_shared", "_cow-bases"]))
  end

  defp save(c, name, object),
    do: File.write!(results(c) <> "/" <> name, Jason.encode!(plain(object)))

  defp plain(%_{} = value), do: value |> Map.from_struct() |> plain()
  defp plain(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, plain(v)} end)
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value), do: value

  defp results(c), do: c.config["root"] <> "/results/" <> c.config["partition"]

  defp timed(c, phase, mode, index, function) do
    File.write!(
      results(c) <> "/stages.jsonl",
      Jason.encode!(%{phase: phase, mode: mode, index: index, event: "started"}) <> "\n",
      [:append, :sync]
    )

    {metrics, result} = ProvisioningMetrics.measure(c.config, function)
    {:ok, usage} = Store.usage(c.store, "benchmark")

    row =
      Map.merge(metrics, %{
        phase: phase,
        mode: mode,
        index: index,
        warmup: index == 0,
        reservation: usage,
        success: true
      })

    File.write!(results(c) <> "/rows.jsonl", Jason.encode!(row) <> "\n", [
      :append,
      :sync
    ])

    IO.puts(Jason.encode!(row))
    result
  rescue
    exception ->
      File.write!(
        results(c) <> "/rows.jsonl",
        Jason.encode!(%{
          phase: phase,
          mode: mode,
          index: index,
          success: false,
          exception: inspect(exception.__struct__)
        }) <> "\n",
        [:append, :sync]
      )

      reraise exception, __STACKTRACE__
  end
end

[config_path, phase] = System.argv()
config = config_path |> File.read!() |> Jason.decode!()
SmolBox.ProvisioningBenchmark.run(config, phase)
