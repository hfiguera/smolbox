defmodule SmolBox.DurableHost.Benchmark do
  @moduledoc "Finite opt-in measurements of the durable host example; no worker provisioning."

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.{Client, Command, Error, Runtime}
  alias SmolBox.DurableHost.{BenchmarkMetrics, BenchmarkSampler, Demo, Store}
  alias SmolBox.Example.Setup

  def run(settings) do
    count = settings["samples"] || 20
    true = is_integer(count) and count in 2..50
    %{"cpu" => cpu, "memory_bytes" => memory} = settings["hardware"]
    true = is_binary(cpu) and byte_size(cpu) in 1..256 and is_integer(memory) and memory > 0
    true = is_binary(settings["database_topology"]) and is_binary(settings["cache_context"])
    false = File.exists?(settings["report"])
    {options, spec, objects, store} = Demo.configure(settings)
    [worker] = options[:workers]
    assert_idle(worker.client)
    worker = %{worker | client: %{worker.client | transport: BenchmarkMetrics}}

    options =
      Keyword.merge(options,
        name: SmolBox.BenchmarkRuntime,
        namespace: "sbxbench",
        workers: [worker],
        max_pending: 4,
        max_active: 4,
        poll_ms: 50,
        telemetry_max_pending: 1024
      )

    :ok = BenchmarkMetrics.open()
    {:ok, runtime} = Runtime.start_link(options)
    context = %{runtime: runtime, spec: spec, objects: objects, store: store, worker: worker}

    try do
      report = measure(context, settings, count)
      assert_idle(worker.client)
      File.write!(settings["report"], Jason.encode!(report, pretty: true) <> "\n", [:exclusive])
      report
    after
      # Durable records and the private settings/keys remain recoverable if a
      # measurement fails. Observer shutdown is never reported as VM cleanup.
      Supervisor.stop(runtime)
      BenchmarkMetrics.close()
    end
  end

  defp measure(context, settings, count) do
    {sequential, sequential_resources} =
      sampled(context, fn ->
        Enum.map(1..count, fn index ->
          context
          |> execute(spec(context, "sequential-#{index}"))
          |> verify_success(context)
        end)
      end)

    {burst, burst_resources} = sampled(context, fn -> burst(context) end)
    {slow, slow_resources} = sampled(context, fn -> slow_consumer(context) end)
    {failures, failure_resources} = sampled(context, fn -> failures(context) end)
    drain_notifications(context.runtime)
    {:ok, notifications} = SmolBox.telemetry_stats(context.runtime)
    true = notifications.available and notifications.dropped == 0 and notifications.timed_out == 0
    {:ok, usage} = Store.usage(context.store, context.worker.client.worker.id)
    true = usage == %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}

    sequential = Enum.map(sequential, &with_metrics/1)

    burst = %{
      burst
      | accepted: Enum.map(burst.accepted, &with_metrics/1),
        blocker: with_metrics(burst.blocker)
    }

    failures = Enum.map(failures, &with_metrics/1)

    %{
      status: "passed",
      platform: :os.type() |> elem(1) |> Atom.to_string(),
      architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> List.to_string(),
      erts: :erlang.system_info(:version) |> List.to_string(),
      schedulers: :erlang.system_info(:schedulers_online),
      hardware: settings["hardware"],
      database_topology: settings["database_topology"],
      cache_context: settings["cache_context"],
      artifact_sha256: settings["artifact_sha256"],
      runtime_version: context.worker.runtime_version,
      profile: Map.take(context.spec.profile, [:cpus, :memory_mb, :storage_gb, :overlay_gb]),
      controller: %{
        max_active: 4,
        max_pending: 4,
        poll_ms: 50,
        lease_ms: 2000,
        telemetry_limit: 1024
      },
      input_bytes: Enum.reduce(context.spec.inputs, 0, &(&1["size"] + &2)),
      observed_end_to_end: "Includes caller/store polling: 25 ms to outcome, 100 ms to cleanup",
      sampling:
        "100 ms; supervised-process heap/mailbox and whole-BEAM memory, not host RSS or hard bounds",
      sequential: sequential,
      burst: burst,
      slow_consumer: %{delay_ms: 2000, result: with_metrics(slow)},
      failures: failures,
      resources: %{
        sequential: sequential_resources,
        burst: burst_resources,
        slow_consumer: slow_resources,
        failures: failure_resources
      },
      remaining_reservations: usage,
      notifications: Map.take(notifications, [:processed, :dropped, :timed_out]),
      cleanup: "Owned records released and entire initially idle worker inventory confirmed empty"
    }
  end

  defp burst(context) do
    blocker =
      command_spec(context, "blocker", "import time; print('started', flush=True); time.sleep(4)")

    started = System.monotonic_time(:microsecond)
    {:ok, handle} = SmolBox.submit(context.runtime, blocker)
    Setup.wait_for(context.runtime, handle, &(&1.state == :running))

    offered =
      Enum.map(1..8, fn index ->
        candidate = spec(context, "burst-#{index}")
        at = System.monotonic_time(:microsecond)
        {candidate, at, SmolBox.submit(context.runtime, candidate)}
      end)

    accepted = for {candidate, at, {:ok, _handle}} <- offered, do: {candidate, at}
    rejected = for {_candidate, _at, {:error, error}} <- offered, do: error
    true = match?([_, _, _, _], accepted) and match?([_, _, _, _], rejected)
    true = Enum.all?(rejected, &match?(%Error{category: :admission_exhausted}, &1))

    observers =
      Enum.map(accepted, fn {candidate, at} ->
        Task.async(fn -> context |> finish(candidate, at) |> verify_success(context) end)
      end)

    blocked = finish(context, blocker, started)
    true = blocked.state == :completed and blocked.exit_code == 0
    completed = Enum.map(observers, &Task.await(&1, 90_000))

    %{
      offered: 8,
      rejected: 4,
      pending_limit: 4,
      worker_slots: 1,
      blocker: blocked,
      accepted: completed
    }
  end

  defp failures(context) do
    original = spec(context, "preparation-failure")
    [input | _rest] = original.inputs
    failed = execute(context, %{original | inputs: [Map.put(input, "source", "missing-input")]})
    true = failed.state == :failed and failed.exit_code == nil

    cancel =
      command_spec(context, "cancel", "import time; print('started', flush=True); time.sleep(4)")

    at = System.monotonic_time(:microsecond)
    {:ok, handle} = SmolBox.submit(context.runtime, cancel)
    Setup.wait_for(context.runtime, handle, &(&1.state == :running))
    {:ok, ^handle} = SmolBox.cancel(context.runtime, cancel.scope, cancel.id)

    retained =
      Setup.wait_for(context.runtime, handle, &(&1.evidence == :termination_confirmed))

    true = retained.state == :unknown and retained.result == nil and retained.reservation != nil
    {:ok, retained_usage} = Store.usage(context.store, context.worker.client.worker.id)
    true = retained_usage.slots == 1
    cancelled = finish(context, cancel, at)
    true = cancelled.state == :unknown and cancelled.exit_code == nil
    [failed, Map.put(cancelled, :reservation_during_uncertainty, retained_usage)]
  end

  defp slow_consumer(context) do
    candidate =
      command_spec(context, "slow-consumer", """
      import os, time
      for _ in range(64):
          os.write(1, b'x' * 8192)
          time.sleep(0.01)
      """)

    at = System.monotonic_time(:microsecond)
    {:ok, _handle} = SmolBox.submit(context.runtime, candidate)

    receive do
    after
      2000 -> :ok
    end

    result = finish(context, candidate, at)
    true = result.state == :completed and result.exit_code == 0 and result.stdout_bytes == 524_288
    result
  end

  defp execute(context, candidate) do
    at = System.monotonic_time(:microsecond)
    {:ok, _handle} = SmolBox.submit(context.runtime, candidate)
    finish(context, candidate, at)
  end

  defp finish(context, candidate, started) do
    handle = {candidate.scope, candidate.id}
    {:ok, result} = SmolBox.await(context.runtime, handle, 90_000)
    observed = System.monotonic_time(:microsecond)

    cleaned =
      Setup.wait_for(
        context.runtime,
        handle,
        &(&1.cleanup == :complete and &1.reservation == nil)
      )

    finished = System.monotonic_time(:microsecond)
    true = cleaned.machine_name != nil

    {:error, %Error{category: :not_found}} =
      Client.inspect_machine(context.worker.client, cleaned.machine_name)

    %{
      id: candidate.id,
      scope: candidate.scope,
      machine: cleaned.machine_name,
      to_outcome_us: observed - started,
      through_cleanup_us: finished - started,
      state: cleaned.state,
      evidence: cleaned.evidence,
      collection: cleaned.collection,
      exit_code: if(result.result, do: result.result.exit_code),
      stdout_bytes: if(result.result, do: byte_size(result.result.stdout), else: 0),
      artifact_bytes: Enum.reduce(cleaned.artifacts, 0, &(&1["size"] + &2))
    }
  end

  defp verify_success(result, context) do
    true = result.state == :completed and result.exit_code == 0 and result.collection == :complete

    {:ok, <<7, 255, 0>>} =
      Directory.read_output(context.objects, {result.scope, result.id}, "output", 32)

    {:ok, "x"} = Directory.read_output(context.objects, {result.scope, result.id}, "count", 32)
    result
  end

  defp spec(context, suffix), do: %{context.spec | id: context.spec.id <> "-" <> suffix}

  defp command_spec(context, suffix, source) do
    {:ok, command} = Command.new(["python", "-u", "-c", source], timeout_secs: 5)
    %{spec(context, suffix) | command: command, inputs: [], outputs: []}
  end

  defp with_metrics(result) do
    metrics = BenchmarkMetrics.execution(result.id, result.machine)
    true = metrics.queue_wait_ms != []

    if result.state == :completed do
      [_duration] = metrics.requests_us.exec

      true =
        Enum.all?(
          [:preparation, :execution, :collection, :cleanup],
          &Map.has_key?(metrics.stages_ms, &1)
        )
    end

    expected_exec = if result.state == :failed, do: 0, else: 1
    true = Map.get(metrics.transport_invocations, :exec, 0) == expected_exec
    Map.put(result, :metrics, metrics)
  end

  defp sampled(context, function) do
    task = BenchmarkSampler.start(context.runtime)

    try do
      result = function.()
      {result, BenchmarkSampler.stop(task)}
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp drain_notifications(runtime, attempts \\ 100)
  defp drain_notifications(_runtime, 0), do: raise("benchmark notifications did not settle")

  defp drain_notifications(runtime, attempts) do
    {:ok, stats} = SmolBox.telemetry_stats(runtime)

    if stats.pending != 0 do
      receive do
      after
        10 -> drain_notifications(runtime, attempts - 1)
      end
    end
  end

  defp assert_idle(client) do
    version = System.get_env("SMOLBOX_RUNTIME_VERSION", "1.14.1")
    {:ok, %{version: ^version, total: 0}} = Client.health(client)
    :ok = Client.readiness(client)
    {:ok, []} = Client.list(client)
  end
end
