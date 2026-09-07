defmodule SmolBox.ManagedRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{
    Client,
    Command,
    Error,
    ExecutionSpec,
    Files,
    Identity,
    Machine,
    MachineSpec,
    Profile,
    Runtime,
    TestArtifacts,
    Worker
  }

  alias SmolBox.Runtime.WorkerConfig
  alias SmolBox.Store.Memory

  @moduletag :runtime
  @moduletag timeout: 120_000

  setup do
    url = System.fetch_env!("SMOLBOX_RUNTIME_URL")
    python = System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT")
    javascript = System.fetch_env!("SMOLBOX_JS_ARTIFACT")
    platform = if :os.type() == {:unix, :darwin}, do: :macos, else: :linux
    architecture = if platform == :macos, do: "aarch64", else: "x86_64"

    artifacts =
      for {id, file} <- [{"python", python}, {"javascript", javascript}] do
        assert File.regular?(file)

        %{
          "id" => id,
          "path" => file,
          "sha256" => digest_file(file),
          "architecture" => architecture
        }
      end

    {:ok, worker} =
      Worker.new("managed", url,
        allow_insecure_loopback: true,
        operation_timeout_ms: 20_000,
        receive_timeout_ms: 15_000
      )

    {:ok, client} = Client.new(worker)
    assert {:ok, _machines} = Client.list(client)
    {:ok, profile} = Profile.new("managed-dev-v1")

    {:ok, configured} =
      WorkerConfig.new(
        client: client,
        architecture: architecture,
        platform: platform,
        artifacts: artifacts,
        profiles: [profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 2}
      )

    store = start_supervised!(Memory)
    objects = start_supervised!({Agent, fn -> %{} end})

    runtime =
      start_supervised!(
        {Runtime,
         [
           name: SmolBox.RealRuntime,
           namespace: "sbxmanaged",
           mode: :ephemeral,
           store: {Memory, store},
           fingerprint_key: :crypto.strong_rand_bytes(32),
           artifact_store: {TestArtifacts, objects},
           workers: [configured],
           poll_ms: 50,
           lease_ms: 5000
         ]}
      )

    %{
      runtime: runtime,
      store: store,
      objects: objects,
      profile: profile,
      artifacts: artifacts,
      client: client
    }
  end

  test "managed Python and JavaScript stage source, retain nonzero exits, collect binary files and clean",
       context do
    for {id, command, script} <- [
          {"python", ["python", "/workspace/main"],
           "import pathlib; pathlib.Path('/workspace/out').write_bytes(bytes([255,0,7])); print('python'); raise SystemExit(7)"},
          {"javascript", ["node", "/workspace/main"],
           "require('node:fs').writeFileSync('/workspace/out', Buffer.from([255,0,7])); console.log('javascript'); process.exit(7);"}
        ] do
      Agent.update(context.objects, &Map.put(&1, {"managed", id}, script))

      spec =
        spec(context, id, command, [
          %{
            "source" => id,
            "path" => "/workspace/main",
            "size" => byte_size(script),
            "sha256" => Files.sha256(script),
            "mode" => "runtime_default"
          }
        ])

      {:ok, handle} = SmolBox.submit(context.runtime, spec)
      own_cleanup(context, handle)
      assert {:ok, result} = SmolBox.await(context.runtime, handle, 30_000)
      assert result.state == :completed
      assert result.result.exit_code == 7
      assert result.result.stdout == id <> "\n"
      assert result.collection == :complete
      assert [%{"sha256" => digest, "size" => 3}] = result.artifacts
      assert digest == Files.sha256(<<255, 0, 7>>)
      cleaned = wait_for(context, handle, &(&1.cleanup == :complete and &1.reservation == nil))
      assert cleaned.evidence == :exited

      assert {:error, %Error{category: :not_found}} =
               Client.inspect_machine(context.client, cleaned.machine_name)
    end
  end

  test "managed cancellation stops the actual VM and preserves uncertainty during evidence retention",
       context do
    spec =
      spec(
        context,
        "python",
        ["python", "-u", "-c", "import time; print('started'); time.sleep(25)"],
        []
      )

    spec = %{spec | outputs: []}
    {:ok, handle} = SmolBox.submit(context.runtime, spec)
    own_cleanup(context, handle)
    running = wait_for(context, handle, &(&1.state == :running))
    assert {:ok, report} = SmolBox.audit_worker(context.runtime, "managed")
    assert Enum.any?(report.candidates, &(&1.status == :owned and &1.execution == handle))
    assert {:ok, ^handle} = SmolBox.cancel(context.runtime, spec.scope, spec.id)
    stopped = wait_for(context, handle, &(&1.evidence == :termination_confirmed))
    assert stopped.state == :unknown
    assert stopped.result == nil
    assert stopped.reservation != nil

    assert {:ok, %Machine{state: :stopped}} =
             Client.inspect_machine(context.client, running.machine_name)

    assert stopped.next_due_at_ms > System.system_time(:millisecond)
  end

  test "orphan inspection leaves a real untracked namespace candidate untouched", context do
    {:ok, name} = Identity.machine_name("sbxmanaged")
    artifact = Enum.find(context.artifacts, &(&1["id"] == "python"))
    {:ok, machine_spec} = MachineSpec.new(name, artifact["path"])
    {:ok, created} = Client.create(context.client, machine_spec)
    on_exit(fn -> remove_owned(context.client, created) end)

    assert {:ok, report} = SmolBox.audit_worker(context.runtime, "managed")
    assert Enum.any?(report.candidates, &(&1.machine_name == name and &1.status == :untracked))

    assert {:error, %Error{category: :not_found}} =
             Memory.find_machine(context.store, "managed", name)

    assert {:ok, observed} = Client.inspect_machine(context.client, name)
    assert Machine.same_incarnation?(created, observed)
    assert observed.state == created.state
  end

  test "a delayed original exec can restart a stopped real VM and is stopped again", context do
    parent = self()

    gate =
      start_supervised!(
        {Agent, fn -> %{event: :exec, phase: :before, observer: parent, fired: false} end},
        id: :delayed_exec_gate
      )

    {counts, port} = SmolBox.RuntimeProxy.start(context.client.worker.base_url, gate)
    {:ok, config} = GenServer.call(Runtime.coordinator(context.runtime), :config)

    {:ok, endpoint} =
      Worker.new("managed", "http://127.0.0.1:#{port}", allow_insecure_loopback: true)

    {:ok, client} = Client.new(endpoint)
    [worker] = config.workers

    options =
      config
      |> Map.from_struct()
      |> Map.delete(:owner)
      |> Map.put(:workers, [%{worker | client: client}])
      |> Map.to_list()

    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, options})
    context = %{context | runtime: runtime}

    spec = %{
      spec(
        context,
        "python",
        ["python", "-u", "-c", "import time; print('late'); time.sleep(10)"],
        []
      )
      | outputs: []
    }

    assert {:ok, handle} = SmolBox.submit(runtime, spec)
    own_cleanup(context, handle)
    assert_receive {:boundary, :exec, :before, blocked}, 10_000
    assert {:ok, ^handle} = SmolBox.cancel(runtime, spec.scope, spec.id)
    stopped = wait_for(context, handle, &(&1.evidence == :termination_confirmed))

    assert {:ok, %Machine{state: :stopped}} =
             Client.inspect_machine(context.client, stopped.machine_name)

    assert Agent.get(counts, & &1) == %{exec: 1, forwarded: 0}
    send(blocked, :release_boundary)

    observed =
      wait_for(context, handle, fn record ->
        record.evidence == :termination_confirmed and
          Enum.any?(
            record.errors,
            &(&1.error.operation == :inspect and &1.error.category == :unknown)
          )
      end)

    assert observed.state == :unknown
    assert observed.result == nil
    assert observed.reservation != nil
    assert Agent.get(counts, & &1) == %{exec: 1, forwarded: 1}

    assert {:ok, %Machine{state: :stopped}} =
             Client.inspect_machine(context.client, observed.machine_name)
  end

  defp spec(context, id, argv, inputs) do
    artifact = Enum.find(context.artifacts, &(&1["id"] == id)) |> Map.delete("path")
    {:ok, command} = Command.new(argv)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "managed",
        id: id,
        artifact: artifact,
        command: command,
        profile: context.profile,
        inputs: inputs,
        outputs: [%{"destination" => "result", "path" => "/workspace/out", "max_bytes" => 32}]
      )

    spec
  end

  defp digest_file(file),
    do:
      File.stream!(file, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

  defp wait_for(context, handle, predicate, attempts \\ 600)
  defp wait_for(_context, _handle, _predicate, 0), do: flunk("managed state deadline elapsed")

  defp wait_for(context, {scope, id} = handle, predicate, attempts) do
    {:ok, record} = SmolBox.fetch(context.runtime, scope, id)
    if predicate.(record), do: record, else: pause(context, handle, predicate, attempts)
  end

  defp pause(context, handle, predicate, attempts) do
    receive do
    after
      50 -> wait_for(context, handle, predicate, attempts - 1)
    end
  end

  defp own_cleanup(context, {scope, id}) do
    # Retain creation evidence outside the observer so the fixture can remove only
    # its verified machine after a failed assertion or retention-window test.
    parent = self()
    watcher = spawn(fn -> watch(context.store, {scope, id}, parent) end)

    on_exit(fn ->
      send(watcher, {:cleanup, self()})

      receive do
        {:owned, nil} -> :ok
        {:owned, created} -> remove_owned(context.client, created)
      after
        1000 -> flunk("ownership evidence watcher did not respond")
      end
    end)
  end

  defp watch(store, key, parent, created \\ nil) do
    reference = Process.monitor(parent)

    receive do
      {:cleanup, reply} -> send(reply, {:owned, created})
      {:DOWN, ^reference, :process, ^parent, _reason} -> await_cleanup(created)
    after
      10 ->
        Process.demonitor(reference, [:flush])

        next =
          case Memory.fetch(store, key) do
            {:ok, record} -> record.created_machine || created
            _missing -> created
          end

        watch(store, key, parent, next)
    end
  end

  defp await_cleanup(created) do
    receive do
      {:cleanup, reply} -> send(reply, {:owned, created})
    after
      5000 -> :ok
    end
  end

  defp remove_owned(client, created) do
    case Client.inspect_machine(client, created.name) do
      {:error, %Error{category: :not_found}} ->
        :ok

      {:ok, observed} ->
        assert Machine.same_incarnation?(created, observed)
        assert {:ok, _stopped} = Client.stop(client, created.name)
        assert :ok = Client.delete(client, created.name)
    end
  end
end
