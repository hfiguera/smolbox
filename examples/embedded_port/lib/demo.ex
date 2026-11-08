defmodule SmolBox.Example.EmbeddedPort do
  @moduledoc "Public managed Port lifecycle using an explicitly approved offline package."
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Backend.Features
  alias SmolBox.{Command, ExecutionSpec, Files, Machines, ManagedMachineSpec, Runtime, Terminal}
  alias SmolBox.Store.{Codec, Memory}
  alias SmolBox.Terminal.Spec, as: TerminalSpec

  def run(target, root, options \\ []) do
    terminal = Keyword.get(options, :terminal, false)
    true = is_boolean(terminal)
    true = not terminal or Features.supports?(target, :terminals)
    root = Path.expand(root)
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    artifacts = Path.join(root, "artifacts")
    :ok = File.mkdir(artifacts)
    :ok = File.chmod(artifacts, 0o700)
    {:ok, objects} = Directory.new(artifacts, max_file_bytes: 2_097_152)
    {store_children, store, mode} = store(options)
    key = Keyword.get_lazy(options, :fingerprint_key, fn -> :crypto.strong_rand_bytes(32) end)

    runtime_options = [
      name: __MODULE__,
      namespace: "portdemo",
      store: store,
      mode: mode,
      artifact_store: {Directory, objects},
      fingerprint_key: key,
      workers: [target] ++ Keyword.get(options, :http_workers, []),
      poll_ms: 50,
      lease_ms: 1000
    ]

    {:ok, supervisor} =
      Supervisor.start_link(store_children ++ [{SmolBox, runtime_options}],
        strategy: :one_for_one
      )

    context = %{
      target: target,
      objects: objects,
      profile: hd(target.profiles),
      artifact: target.artifacts |> hd() |> Map.take(~w(id sha256 architecture)),
      supervisor: supervisor,
      store: store,
      http_workers: Keyword.get(options, :http_workers, []),
      root: root,
      terminal: terminal
    }

    try do
      ready(target.id)
      evidence = lifecycle(context)
      evidence = Map.put(evidence, "store_mode", Atom.to_string(mode))
      File.write!(Path.join(root, "evidence.json"), Jason.encode!(evidence), [:exclusive])
      File.chmod!(Path.join(root, "evidence.json"), 0o600)
      evidence
    after
      try do
        checkpoint(context, "before-shutdown")
        :ok = Supervisor.terminate_child(supervisor, {Runtime, __MODULE__})
        checkpoint(context, "after-shutdown")
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  defp store(options) do
    case Keyword.fetch(options, :store) do
      {:ok, adapter} ->
        {[], adapter, Keyword.fetch!(options, :mode)}

      :error ->
        {[{Memory, name: Module.concat(__MODULE__, Store)}],
         {Memory, Module.concat(__MODULE__, Store)}, :ephemeral}
    end
  end

  defp lifecycle(context) do
    disposable = command(context, "disposable", "printf disposable; exit 7")
    {:ok, disposable_handle} = SmolBox.submit(__MODULE__, disposable)
    completed(disposable_handle, 7)
    clean(disposable_handle)

    {:ok, specification} =
      ManagedMachineSpec.new(
        scope: "portdemo",
        id: "retained",
        profile: context.profile,
        artifact: context.artifact
      )

    {:ok, machine} = Machines.create(__MODULE__, specification)
    %{state: :stopped} = idle(machine)
    checkpoint(context, "created")
    lifecycle_request(machine, :start, :running)
    terminal_evidence = terminal(context, machine)
    data = :binary.copy(<<0, 255>>, 524_296) <> <<42>>
    :ok = Directory.seed(context.objects, "portdemo", "input", data)
    write = command(context, "write", "cat /workspace/in.bin > /workspace/retained.bin; exit 7")

    input = %{
      "source" => "input",
      "path" => "/workspace/in.bin",
      "size" => byte_size(data),
      "sha256" => Files.sha256(data),
      "mode" => "runtime_default"
    }

    {:ok, write_handle} = Machines.submit(__MODULE__, machine, %{write | inputs: [input]})
    completed(write_handle, 7)
    %{state: :running} = idle(machine)
    :ok = SmolBox.drain_worker(__MODULE__, context.target.id)

    queued = %{disposable | id: "while-draining", queue_ms: 500}
    {:ok, queued_handle} = SmolBox.submit(__MODULE__, queued)
    {:ok, %{state: :expired, worker_id: nil}} = SmolBox.await(__MODULE__, queued_handle, 10_000)
    read_retained(context, machine, "read-while-draining", data)
    http_while_draining(context)
    lifecycle_request(machine, :stop, :stopped)

    {:ok, %{assessment: :blocked, reserved: %{slots: 1}}} =
      SmolBox.worker_maintenance(__MODULE__, context.target.id)

    :ok = Supervisor.terminate_child(context.supervisor, {Runtime, __MODULE__})
    {:ok, _runtime} = Supervisor.restart_child(context.supervisor, {Runtime, __MODULE__})
    ready(context.target.id)
    %{state: :stopped} = idle(machine)
    {:ok, report} = SmolBox.worker_maintenance(__MODULE__, context.target.id)
    true = report.control.mode == :draining

    {:ok, %{mode: :active}} =
      SmolBox.resume_worker(__MODULE__, context.target.id, report.control.version)

    lifecycle_request(machine, :start, :running)
    read_retained(context, machine, "read-after-restart", data)
    lifecycle_request(machine, :stop, :stopped)
    lifecycle_request(machine, :delete, :deleted)
    :ok = SmolBox.drain_worker(__MODULE__, context.target.id)
    {:ok, final} = SmolBox.worker_maintenance(__MODULE__, context.target.id)
    true = final.records == [] and final.reserved.slots == 0

    %{
      "scope" => "public-managed-port-lifecycle",
      "proof" => "passed",
      "package_manifest_sha256" => context.target.package_manifest_sha256,
      "identity" => context.target.package_identity,
      "fixture_sha256" => context.artifact["sha256"],
      "public_native_admission_enabled" => true,
      "disposable_exit" => 7,
      "retained_write_exit" => 7,
      "file_bytes" => byte_size(data),
      "file_sha256" => Files.sha256(data),
      "drain_blocks_new_assignments" => true,
      "existing_command_while_draining" => true,
      "retained_after_normal_runtime_restart" => true,
      "drain_survives_runtime_restart" => true,
      "resume_version_checked" => true,
      "owned_deleted" => true,
      "final_reserved_slots" => final.reserved.slots,
      "http_workers_exercised_while_native_draining" => length(context.http_workers),
      "deliberate_process_interruption" => false,
      "crash_handling_qualified" => false,
      "terminal" => terminal_evidence
    }
  end

  defp terminal(%{terminal: false}, _machine), do: %{"exercised" => false}

  defp terminal(context, machine) do
    {:ok, terminal} =
      TerminalSpec.new(session_ms: 30_000, idle_ms: 15_000, max_buffer_bytes: 65_536)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "portdemo",
        id: "terminal",
        artifact: context.artifact,
        profile: context.profile,
        command: terminal
      )

    {:ok, key} = Terminal.open(__MODULE__, machine, spec)
    {:ok, ^key} = Terminal.open(__MODULE__, machine, spec)
    {:ok, handle} = Terminal.attach(__MODULE__, key, 10_000)
    :ok = Terminal.input(handle, "stty -echo; printf 'SB_TTY_%s\\n' READY\n")
    terminal_marker(handle, "SB_TTY_READY")
    :ok = Terminal.resize(handle, 120, 43)
    :ok = Terminal.input(handle, "stty size; printf 'SB_TTY_%s\\n' SIZE\n")
    size = terminal_marker(handle, "SB_TTY_SIZE")
    true = :binary.match(size, "43 120") != :nomatch
    :ok = Terminal.input(handle, "printf '\\000\\377\\200'; printf 'SB_TTY_%s\\n' OUTPUT\n")
    output = terminal_marker(handle, "SB_TTY_OUTPUT")
    true = :binary.match(output, <<0, 255, 128>>) != :nomatch
    # Only this owned guest PTY changes mode. No host tty or signal API is used.
    :ok =
      Terminal.input(
        handle,
        "stty -echo -icanon min 1 time 0; printf 'SB_TTY_%s\\n' INPUT_READY; dd bs=1 count=3 2>/dev/null | od -An -t u1; stty sane -echo; printf 'SB_TTY_%s\\n' INPUT_DONE\n"
      )

    terminal_marker(handle, "SB_TTY_INPUT_READY")
    :ok = Terminal.input(handle, <<0, 255, 128>>)
    input = terminal_marker(handle, "SB_TTY_INPUT_DONE")
    true = Regex.match?(~r/\b0\s+255\s+128\b/, input)
    :ok = Terminal.input(handle, "exit 7\n")
    terminal_exit(handle, System.monotonic_time(:millisecond) + 10_000)
    record = completed(key, 7)
    %{state: :running} = idle(machine)
    {:ok, <<"smolbox-record-v17\0", _::binary>> = encoded} = Codec.encode(record)
    {:ok, ^record} = Codec.decode(encoded)

    %{
      "exercised" => true,
      "scope" => "ordinary-public-retained-image-pty",
      "observed_exit" => 7,
      "binary_input_bytes" => 3,
      "binary_output_verified" => true,
      "resize" => %{"cols" => 120, "rows" => 43},
      "codec" => 17,
      "duplicate_open_reuses_execution" => true,
      "slot_released" => true,
      "transcript_persisted" => false,
      "deliberate_process_interruption" => false
    }
  end

  defp terminal_marker(handle, marker),
    do: terminal_marker(handle, marker, <<>>, System.monotonic_time(:millisecond) + 10_000)

  defp terminal_marker(handle, marker, bytes, deadline) do
    true = byte_size(bytes) <= 65_536 and System.monotonic_time(:millisecond) < deadline

    case Terminal.next(handle, min(1000, max(0, deadline - System.monotonic_time(:millisecond)))) do
      {:ok, {:output, chunk}} ->
        next = bytes <> chunk
        true = byte_size(next) <= 65_536

        if :binary.match(next, marker) != :nomatch,
          do: next,
          else: terminal_marker(handle, marker, next, deadline)

      {:error, %{category: :expired}} ->
        terminal_marker(handle, marker, bytes, deadline)

      _ ->
        raise "ordinary terminal observation failed"
    end
  end

  defp terminal_exit(handle, deadline) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.next(handle, min(1000, max(0, deadline - System.monotonic_time(:millisecond)))) do
      {:ok, {:closed, {:ok, %{exit_code: 7}}}} -> :ok
      {:ok, {:output, _}} -> terminal_exit(handle, deadline)
      {:error, %{category: :expired}} -> terminal_exit(handle, deadline)
      _ -> raise "ordinary terminal Exit was not confirmed"
    end
  end

  # These are private forensic records, not a durable store or an import API.
  # Preserve the authentic authority; never recreate receipts from SDK inventory.
  defp checkpoint(context, label) do
    {adapter, store} = context.store
    records = records(adapter, store, context.target.id, nil)

    encoded =
      Enum.map(records, fn record ->
        {:ok, bytes} = Codec.encode(record)
        Base.encode64(bytes)
      end)

    path = Path.join(context.root, "private-records-#{label}.json")
    File.write!(path, Jason.encode!(encoded), [:exclusive])
    File.chmod!(path, 0o600)
  end

  defp records(adapter, store, worker, cursor) do
    {:ok, page, next} = adapter.backend_assignments(store, worker, cursor, 100)
    if next, do: page ++ records(adapter, store, worker, next), else: page
  end

  defp command(context, id, script) do
    {:ok, command} = Command.new(["/bin/sh", "-c", script], workdir: "/workspace")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "portdemo",
        id: id,
        profile: context.profile,
        artifact: context.artifact,
        command: command
      )

    spec
  end

  defp http_while_draining(context) do
    Enum.each(context.http_workers, fn worker ->
      ready(worker.client.worker.id)

      http = %{
        context
        | profile: hd(worker.profiles),
          artifact: worker.artifacts |> hd() |> Map.take(~w(id sha256 architecture))
      }

      {:ok, handle} =
        SmolBox.submit(__MODULE__, command(http, "http-while-draining", "printf http; exit 7"))

      %{worker_id: id} = completed(handle, 7)
      true = id == worker.client.worker.id
      clean(handle)
    end)
  end

  defp read_retained(context, machine, id, expected) do
    spec = command(context, id, "test -f /workspace/retained.bin; exit $?")

    output = %{
      "destination" => "retained",
      "path" => "/workspace/retained.bin",
      "max_bytes" => 2_097_152
    }

    {:ok, handle} = Machines.submit(__MODULE__, machine, %{spec | outputs: [output]})
    completed(handle, 0)
    {:ok, ^expected} = Directory.read_output(context.objects, handle, "retained", 2_097_152)
    %{state: :running} = idle(machine)
  end

  defp lifecycle_request(handle, operation, expected, retries \\ 10) do
    current = idle(handle)

    case apply(Machines, operation, [__MODULE__, handle, current.version]) do
      {:ok, _accepted} ->
        %{state: ^expected} = idle(handle)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle_request(handle, operation, expected, retries - 1)

      error ->
        raise "lifecycle request rejected: #{inspect(error)}"
    end
  end

  defp completed(handle, expected_exit) do
    {:ok, record} = SmolBox.await(__MODULE__, handle, 180_000)
    %{state: :completed, result: %{exit_code: ^expected_exit}} = record
    record
  end

  defp idle(handle) do
    {:ok, record} = Machines.await(__MODULE__, handle, 180_000)
    record
  end

  defp clean(handle) do
    wait(fn ->
      {:ok, record} = SmolBox.fetch(__MODULE__, elem(handle, 0), elem(handle, 1))
      record.cleanup == :complete and record.reservation == nil
    end)
  end

  defp ready(id) do
    wait(fn ->
      {:ok, workers} = SmolBox.workers(__MODULE__)
      Enum.any?(workers, &(&1.id == id and &1.health_status == :ready))
    end)
  end

  defp wait(check), do: wait(check, System.monotonic_time(:millisecond) + 180_000)

  defp wait(check, deadline) do
    unless check.() do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("public lifecycle wait expired")

      Process.sleep(50)
      wait(check, deadline)
    end
  end
end
