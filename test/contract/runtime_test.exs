defmodule SmolBox.RuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Error, ExecutionSpec, Files, ManagedPeer, Runtime}
  alias SmolBox.Runtime.Config
  alias SmolBox.Store.Memory

  defp setup_runtime(options \\ []), do: SmolBox.RuntimeFixture.start(options)

  test "durable mode rejects an ephemeral or unavailable store before worker I/O" do
    context = setup_runtime()

    assert {:error, %Error{category: :unsupported_capability}} =
             Config.new(Keyword.put(context.options, :mode, :durable))

    assert {:error, %Error{category: :store}} =
             Config.new(Keyword.put(context.options, :store, {Memory, :missing}))

    refute inspect(elem(Config.new(context.options), 1)) =~ Base.encode64(:binary.copy(<<2>>, 32))
  end

  test "managed submission outlives its caller and stages, collects, and releases an owned machine" do
    context = setup_runtime()

    inputs = [
      %{
        "source" => "input",
        "path" => "/workspace/in.bin",
        "size" => 2,
        "sha256" => Files.sha256(<<0, 255>>),
        "mode" => "runtime_default"
      }
    ]

    outputs = [%{"destination" => "output", "path" => "/workspace/out.bin", "max_bytes" => 32}]
    spec = %{context.spec | inputs: inputs, outputs: outputs}
    assert :ok = ExecutionSpec.validate(spec)
    task = Task.async(fn -> SmolBox.submit(context.runtime, spec) end)
    assert {:ok, handle} = Task.await(task)
    assert {:ok, ^handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, result} = SmolBox.await(context.runtime, handle, 5000)
    assert result.state == :completed
    assert result.result.exit_code == 7
    assert result.result.stdout == "started"
    assert result.collection == :complete
    assert [%{"size" => 3, "sha256" => digest}] = result.artifacts
    assert digest == Files.sha256(<<0, 255, 17>>)

    clean =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, spec.scope, spec.id)
        if record.cleanup == :complete and record.reservation == nil, do: record
      end)

    assert clean.result == result.result
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
    assert ManagedPeer.snapshot(context.peer).machines == %{}

    assert Agent.get(context.artifacts, &Map.fetch!(&1, {handle, "output"})) ==
             {<<0, 255, 17>>, digest}

    assert {:error, %Error{category: :identity_conflict}} =
             SmolBox.submit(context.runtime, %{spec | metadata: %{"changed" => true}})
  end

  test "observer timeout leaves execution active and cancellation confirms termination without inventing exit" do
    context = setup_runtime(hold: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    eventually(fn -> match?([_command], ManagedPeer.snapshot(context.peer).commands) end)
    assert {:error, %Error{category: :expired}} = SmolBox.await(context.runtime, handle, 0)
    assert {:ok, ^handle} = SmolBox.cancel(context.runtime, context.spec.scope, context.spec.id)

    stopped =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
        if record.evidence == :termination_confirmed, do: record
      end)

    assert stopped.state == :unknown
    assert stopped.result == nil
    assert stopped.reservation != nil
    assert stopped.next_due_at_ms > System.system_time(:millisecond)
    assert SmolBox.reconcile(context.runtime, context.spec.scope, context.spec.id) == :ok
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
  end

  test "missing output preserves the command exit and still cleans the machine" do
    context = setup_runtime()

    spec = %{
      context.spec
      | outputs: [
          %{"destination" => "missing", "path" => "/workspace/missing", "max_bytes" => 16}
        ]
    }

    assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, result} = SmolBox.await(context.runtime, handle, 5000)
    assert result.state == :collection_failed
    assert result.result.exit_code == 7
    assert result.collection == :failed
    eventually(fn -> ManagedPeer.snapshot(context.peer).machines == %{} end)
  end

  test "a restarted observer retains the original command and never replays it" do
    context = setup_runtime(hold: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    eventually(fn -> match?([_command], ManagedPeer.snapshot(context.peer).commands) end)
    stop_supervised!(Runtime)
    runtime = start_supervised!({Runtime, context.options})
    assert {:ok, ^handle} = SmolBox.submit(runtime, context.spec)

    recovered =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(runtime, context.spec.scope, context.spec.id)
        if record.evidence == :termination_confirmed, do: record
      end)

    assert recovered.state == :unknown
    assert recovered.result == nil
    assert recovered.reservation != nil
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
  end

  test "ambiguous creation never adopts a machine using its name alone" do
    context = setup_runtime(create_lost: true)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, failed} = SmolBox.await(context.runtime, handle, 5000)
    assert failed.state == :failed
    assert failed.evidence == :not_dispatched

    record =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
        if record.cleanup == :failed, do: record
      end)

    assert record.created_machine == nil
    assert record.reservation != nil
    assert record.last_error.category == :identity_conflict
    assert ManagedPeer.snapshot(context.peer).commands == []
    assert map_size(ManagedPeer.snapshot(context.peer).machines) == 1
  end

  test "cleanup retries preserve an observed exit; exhaustion retains capacity" do
    context = setup_runtime(delete_failures: 100)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, result} = SmolBox.await(context.runtime, handle, 5000)

    failed =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
        if record.cleanup == :failed, do: record
      end)

    assert failed.result == result.result
    assert failed.state == :completed
    assert failed.reservation != nil
    assert failed.cleanup_attempts == 5

    assert Enum.count(ManagedPeer.snapshot(context.peer).operations, &(elem(&1, 0) == "DELETE")) ==
             5
  end

  test "a transient delete failure is inspected and retried without repeating command execution" do
    context = setup_runtime(delete_failures: 1)
    assert {:ok, _handle} = SmolBox.submit(context.runtime, context.spec)

    clean =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
        if record.cleanup == :complete and record.reservation == nil, do: record
      end)

    assert clean.result.exit_code == 7
    assert clean.cleanup_attempts == 2
    assert match?([_command], ManagedPeer.snapshot(context.peer).commands)
  end

  test "draining, bounded pending admission, and pre-dispatch cancellation do no guest work" do
    context = setup_runtime(draining: true, max_pending: 1)
    assert {:ok, handle} = SmolBox.submit(context.runtime, context.spec)
    assert {:ok, ^handle} = SmolBox.submit(context.runtime, context.spec)

    assert {:error, %Error{category: :admission_exhausted}} =
             SmolBox.submit(context.runtime, %{context.spec | id: "second"})

    assert {:ok, [%{status: :draining}]} = SmolBox.workers(context.runtime)
    assert {:ok, ^handle} = SmolBox.cancel(context.runtime, context.spec.scope, context.spec.id)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :cancelled
    assert record.evidence == :not_dispatched
    assert record.cleanup == :complete
    assert record.machine_name == nil
    assert ManagedPeer.snapshot(context.peer).commands == []
    assert :ok = SmolBox.drain_worker(context.runtime, "peer")

    assert {:error, %Error{category: :not_found}} =
             SmolBox.drain_worker(context.runtime, "foreign")
  end

  test "unsupported policies and invalid public requests fail before admission" do
    context = setup_runtime()

    assert {:error, %Error{category: :unsupported_capability}} =
             SmolBox.submit(context.runtime, %{
               context.spec
               | profile: %{context.spec.profile | id: "other"}
             })

    assert {:error, %Error{category: :validation}} = SmolBox.submit(context.runtime, %{})

    assert {:error, %Error{category: :validation}} =
             SmolBox.fetch(context.runtime, "../bad", "id")

    assert {:error, %Error{category: :validation}} = SmolBox.await(context.runtime, :bad, 1)

    assert {:error, %Error{category: :validation}} =
             SmolBox.await(context.runtime, {"ok", "id"}, -1)

    assert {:error, %Error{category: :not_found}} =
             SmolBox.reconcile(context.runtime, "ok", "missing")

    assert {:error, %Error{}} = SmolBox.fetch(:missing_runtime, "ok", "id")
  end

  test "a failed input digest prevents dispatch and cleans the prepared machine" do
    context = setup_runtime()

    spec = %{
      context.spec
      | inputs: [
          %{
            "source" => "input",
            "path" => "/workspace/in",
            "size" => 2,
            "sha256" => Files.sha256("wrong"),
            "mode" => "runtime_default"
          }
        ]
    }

    assert {:ok, handle} = SmolBox.submit(context.runtime, spec)
    assert {:ok, record} = SmolBox.await(context.runtime, handle, 5000)
    assert record.state == :failed
    assert record.last_error.operation == :artifact_store
    assert ManagedPeer.snapshot(context.peer).commands == []
    eventually(fn -> ManagedPeer.snapshot(context.peer).machines == %{} end)
  end

  test "an exhausted cleanup can observe operator-confirmed absence without sending more mutations" do
    context = setup_runtime(delete_failures: 100)
    assert {:ok, _handle} = SmolBox.submit(context.runtime, context.spec)

    eventually(fn ->
      {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
      record.cleanup == :failed
    end)

    Agent.update(context.peer, &%{&1 | machines: %{}})
    assert :ok = SmolBox.reconcile(context.runtime, context.spec.scope, context.spec.id)

    eventually(fn ->
      {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
      record.cleanup == :complete and record.reservation == nil
    end)

    assert Enum.count(ManagedPeer.snapshot(context.peer).operations, &(elem(&1, 0) == "DELETE")) ==
             5
  end

  test "a changed machine incarnation survives cleanup and its reservation remains charged" do
    context = setup_runtime(hold: true)
    assert {:ok, _handle} = SmolBox.submit(context.runtime, context.spec)
    eventually(fn -> match?([_command], ManagedPeer.snapshot(context.peer).commands) end)

    Agent.update(context.peer, fn state ->
      machines =
        Map.new(state.machines, fn {name, machine} ->
          {name, Map.update!(machine, "createdAt", &(&1 + 1))}
        end)

      %{state | machines: machines}
    end)

    assert {:ok, _handle} = SmolBox.cancel(context.runtime, context.spec.scope, context.spec.id)

    foreign =
      eventually(fn ->
        {:ok, record} = SmolBox.fetch(context.runtime, context.spec.scope, context.spec.id)
        if record.cleanup == :failed, do: record
      end)

    assert foreign.last_error.category == :identity_conflict
    assert foreign.evidence == :unknown
    assert foreign.reservation != nil

    refute Enum.any?(ManagedPeer.snapshot(context.peer).operations, fn {method, path} ->
             method == "DELETE" or String.ends_with?(path, "/stop")
           end)
  end

  defp eventually(function, attempts \\ 200)
  defp eventually(_function, 0), do: flunk("condition did not become true")

  defp eventually(function, attempts) do
    case function.() do
      value when value not in [nil, false] ->
        value

      _pending ->
        receive do
        after
          25 -> eventually(function, attempts - 1)
        end
    end
  end
end
