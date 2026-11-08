defmodule SmolBox.Example.EmbeddedVolumes do
  @moduledoc """
  Explicit ordinary public mounted-volume acceptance for an approved Linux Port
  target. Memory supports `:single`; durable adapters also support normal
  `:prepare` / `:resume` runs in separate BEAMs with the same keys and store.

  No SDK, VM or owner-loss faults are injected. Unexpected outcomes retain the
  original Runtime and store for the bounded, version-checked control receiver.
  Receipt-bearing checkpoints and fingerprint material remain private.
  """
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Embedded.Config
  alias SmolBox.Example.EmbeddedVolumeControl
  alias SmolBox.Store.{Codec, Memory}

  alias SmolBox.{
    Command,
    ExecutionSpec,
    Files,
    GuestPaths,
    Machines,
    ManagedMachineSpec,
    Profile,
    Runtime,
    Volume,
    VolumeMount,
    VolumePolicy,
    Volumes
  }

  def configure(%Config{platform: :linux} = target, volume_root) do
    {:ok, paths} = GuestPaths.new(download_roots: ["/workspace", "/mnt/volumes/data"])

    {:ok, profile} =
      Profile.new("public-volume-offline",
        cpus: 1,
        memory_mb: 512,
        preparation_ms: 120_000,
        execution_ms: 30_000,
        max_file_bytes: 131_072,
        guest_paths: paths
      )

    {:ok, policy} = VolumePolicy.new("public-volume-proof", volume_root)

    target = %{
      target
      | profiles: [profile],
        volume_policy: policy,
        capacity: %{slots: 2, cpus: 2, memory_mb: 1536, disk_gb: 10}
    }

    :ok = Config.validate(target)
    true = Config.sdk_identity(target)["feature_versions"]["volumes"] == 1
    target
  end

  def run(%Config{platform: :linux} = target, output, options \\ []) do
    Process.flag(:trap_exit, true)
    Process.put({__MODULE__, :closed}, false)
    phase = Keyword.get(options, :phase, :single)
    scope = Keyword.get(options, :scope, "public-volume-proof")
    true = phase in [:single, :prepare, :resume] and SmolBox.Validation.identifier?(scope)
    {children, store, mode} = store(options)
    true = phase == :single or mode == :durable

    key =
      Keyword.get_lazy(options, :fingerprint_key, fn ->
        true = mode == :ephemeral
        :crypto.strong_rand_bytes(32)
      end)

    true = is_binary(key) and byte_size(key) == 32
    expected = expected(options, phase)
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)
    objects_path = artifact_root(options, phase, output)
    {:ok, objects} = Directory.new(objects_path, max_file_bytes: 131_072)
    save(output, "private-fingerprint", Base.encode64(key))

    runtime_options = [
      name: __MODULE__,
      namespace: "portvol",
      mode: mode,
      store: store,
      artifact_store: {Directory, objects},
      fingerprint_key: key,
      workers: [target],
      lease_ms: 1000,
      poll_ms: 50
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children ++ [{SmolBox, runtime_options}], strategy: :one_for_one)

    c = %{
      root: output,
      supervisor: supervisor,
      objects: objects,
      target: target,
      profile: hd(target.profiles),
      artifact: hd(target.artifacts) |> Map.take(~w(id sha256 architecture)),
      store: store,
      mode: mode,
      phase: phase,
      scope: scope
    }

    try do
      result = execute(c, expected)

      evidence =
        Map.merge(result, %{
          scope: "public-linux-mounted-runtime",
          phase: phase,
          package_manifest_sha256: target.package_manifest_sha256,
          identity: target.package_identity,
          fixture_sha256: c.artifact["sha256"],
          worker_capacity: target.capacity,
          store_mode: mode,
          deliberate_process_interruption: false,
          crash_handling_qualified: false
        })

      save(output, "evidence", evidence)
      {:ok, evidence}
    rescue
      error -> retain(c, diagnostics(error, __STACKTRACE__))
    catch
      kind, _ -> retain(c, %{exception: inspect(kind)})
    end
  end

  defp execute(%{phase: :single} = c, _) do
    held = prepare(c)
    :ok = Supervisor.terminate_child(c.supervisor, {Runtime, __MODULE__})
    {:ok, _} = Supervisor.restart_child(c.supervisor, {Runtime, __MODULE__})
    result = resume(c, held)
    :ok = close(c)
    result
  end

  defp execute(%{phase: :prepare} = c, _) do
    held = prepare(c)
    %{state: :stopped} = idle({c.scope, "original"})
    true = held.attached_to == {c.scope, "original"}
    usage(c, 1, 4)
    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    %{prepared_stopped: true, owned_deleted: false, reserved_slots: 1, reserved_disk_gb: 4}
  end

  defp execute(%{phase: :resume} = c, expected) do
    ready(c)
    {:ok, held} = Volumes.inspect(__MODULE__, {c.scope, "data"})
    before = Enum.find(expected, &match?(%Volume{id: "data"}, &1))
    true = held == before and held.scope == c.scope
    original = Enum.find(expected, &match?(%SmolBox.ManagedMachine{id: "original"}, &1))
    %{state: :stopped} = current = idle({c.scope, "original"})
    true = original.scope == c.scope and current.backend_assignment == original.backend_assignment
    true = current.native_mounts == original.native_mounts
    {:ok, kept} = Directory.read_output(c.objects, {c.scope, "first-read"}, "kept", 131_072)
    true = kept == data()
    result = resume(c, held)
    :ok = close(c)

    result
    |> Map.put(:separate_normal_beam_restart, true)
    |> Map.put(:historical_output_after_normal_beam_restart, true)
  end

  defp store(options) do
    case Keyword.fetch(options, :store) do
      {:ok, adapter} -> {[], adapter, Keyword.fetch!(options, :mode)}
      :error -> {[{Memory, name: __MODULE__.Store}], {Memory, __MODULE__.Store}, :ephemeral}
    end
  end

  defp artifact_root(options, phase, output) do
    case Keyword.fetch(options, :artifact_root) do
      {:ok, root} ->
        root

      :error ->
        true = phase == :single
        root = Path.join(output, "objects")
        :ok = File.mkdir(root)
        :ok = File.chmod(root, 0o700)
        root
    end
  end

  defp expected(options, :resume) do
    path = Keyword.fetch!(options, :expected_records)
    true = File.stat!(path).size <= 1_048_576
    records = path |> File.read!() |> Jason.decode!()
    true = is_list(records) and Enum.count_until(records, 1025) <= 1024

    Enum.map(records, fn encoded ->
      {:ok, bytes} = Base.decode64(encoded)
      {:ok, record} = Codec.decode(bytes)
      record
    end)
  end

  defp expected(_, _), do: []
  defp data, do: :binary.copy(<<0, 255, 128>>, 21_851) <> <<42>>

  @doc false
  def diagnostics(error, stack) do
    failure =
      case error do
        %MatchError{term: {:error, %SmolBox.Error{} = rejected}} ->
          Map.take(rejected, [:category, :operation, :evidence])

        _ ->
          nil
      end

    frames =
      stack
      |> Enum.take(8)
      |> Enum.map(fn {module, function, args, location} ->
        %{
          module: Atom.to_string(module),
          function: Atom.to_string(function),
          arity: if(is_list(args), do: length(args), else: args),
          line: location[:line]
        }
      end)

    %{exception: inspect(error.__struct__), rejected: failure, frames: frames}
  end

  defp retain(c, diagnostic) do
    # A diagnostic failure must not unwind the original owner or its store.
    try do
      save(c.root, "failure", diagnostic)
      checkpoint(c, "failure")
    rescue
      _ -> :diagnostic_unavailable
    catch
      _, _ -> :diagnostic_unavailable
    end

    unless Process.get({__MODULE__, :closed}), do: EmbeddedVolumeControl.wait(c, &close/1)
    {:error, :qualification_failed}
  end

  defp prepare(c) do
    ready(c)

    {:ok, volume} = create_volume(c, "data", 2)

    {:ok, %{state: :ready} = provisioned} = Volumes.inspect(__MODULE__, volume)
    true = provisioned.native_authority.provision != nil

    {:ok, ^volume} = create_volume(c, "data", 2)

    usage(c, 0, 2)
    checkpoint(c, "provisioned")
    original = create(c, "original", false)
    {:ok, held} = Volumes.inspect(__MODULE__, volume)
    true = held.attached_to == original
    {:error, %{evidence: :not_dispatched}} = Volumes.delete(__MODULE__, volume, held.version)
    {:error, _} = Machines.create(__MODULE__, specification(c, "contender", true))
    {:error, %{category: :not_found}} = Machines.inspect(__MODULE__, {c.scope, "contender"})
    lifecycle(original, :start, :running)
    usage(c, 1, 4)

    {:error, %{evidence: :not_dispatched}} =
      Volumes.create(__MODULE__, scope: c.scope, id: "budget", worker_id: c.target.id, size_gb: 9)

    {:error, %{category: :not_found}} = Volumes.inspect(__MODULE__, {c.scope, "budget"})
    usage(c, 1, 4)
    bytes = data()
    :ok = Directory.seed(c.objects, c.scope, "input", bytes)

    input = %{
      "source" => "input",
      "path" => "/workspace/in.bin",
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

    spec = command(c, "write", "cat /workspace/in.bin > /mnt/volumes/data/kept.bin; exit 7")
    completed(original, %{spec | inputs: [input]}, 7)
    read(c, original, "first-read", bytes)

    {:ok, sibling} = create_volume(c, "sibling", 1)

    {:ok, current} = Volumes.inspect(__MODULE__, sibling)
    {:ok, %{state: :deleted}} = delete_volume(sibling, current)
    %{state: :running} = idle(original)
    usage(c, 1, 4)
    :ok = SmolBox.drain_worker(__MODULE__, c.target.id)

    {:error, _} =
      Volumes.create(__MODULE__,
        scope: c.scope,
        id: "rejected",
        worker_id: c.target.id,
        size_gb: 1
      )

    {:error, %{category: :not_found}} = Volumes.inspect(__MODULE__, {c.scope, "rejected"})
    read(c, original, "while-draining", bytes)
    lifecycle(original, :stop, :stopped)
    checkpoint(c, "before-replacement")
    held
  end

  defp resume(c, held) do
    original = {c.scope, "original"}
    volume = {c.scope, "data"}
    bytes = data()
    ready(c)
    {:ok, recovered} = Volumes.inspect(__MODULE__, volume)
    true = recovered == held
    %{state: :stopped} = idle(original)
    {:ok, maintenance} = SmolBox.worker_maintenance(__MODULE__, c.target.id)
    true = maintenance.control.mode == :draining

    {:ok, %{mode: :active}} =
      SmolBox.resume_worker(__MODULE__, c.target.id, maintenance.control.version)

    lifecycle(original, :start, :running)
    read(c, original, "after-replacement", bytes)

    completed(
      original,
      command(
        c,
        "new-write",
        "printf new > /mnt/volumes/data/new.bin; test -s /mnt/volumes/data/new.bin"
      ),
      0
    )

    lifecycle(original, :stop, :stopped)
    lifecycle(original, :delete, :deleted)
    usage(c, 0, 2)
    readonly = create(c, "readonly", true)
    lifecycle(readonly, :start, :running)
    read(c, readonly, "read-only", bytes)

    completed(
      readonly,
      command(
        c,
        "deny-write",
        "if printf denied > /mnt/volumes/data/denied.bin; then exit 1; else exit 7; fi"
      ),
      7
    )

    lifecycle(readonly, :stop, :stopped)
    lifecycle(readonly, :delete, :deleted)
    {:ok, free} = Volumes.inspect(__MODULE__, volume)
    true = free.attached_to == nil and free.native_authority == held.native_authority
    {:ok, %{state: :deleted} = deleted} = delete_volume(volume, free)

    true =
      deleted.native_authority.deletion["provision"] == held.native_authority.provision

    {:ok, ^deleted} = delete_volume(volume, free)
    usage(c, 0, 0)
    checkpoint(c, "completed")

    %{
      file_bytes: byte_size(bytes),
      file_sha256: Files.sha256(bytes),
      readonly_reattachment: true,
      stopped_runtime_replacement: true,
      drain_retained: true,
      running_sibling_preserved: true,
      competing_attachment_rejected: true,
      volume_budget_rejected_before_dispatch: true,
      proof_retained: true,
      owned_deleted: true,
      final_reserved_slots: 0,
      final_reserved_disk_gb: 0
    }
  end

  defp create_volume(c, id, size) do
    retry_admission(
      fn ->
        Volumes.create(__MODULE__, scope: c.scope, id: id, worker_id: c.target.id, size_gb: size)
      end,
      fn ->
        match?({:error, %{category: :not_found}}, Volumes.inspect(__MODULE__, {c.scope, id}))
      end
    )
  end

  defp delete_volume(key, volume) do
    retry_admission(
      fn -> Volumes.delete(__MODULE__, key, volume.version) end,
      fn -> match?({:ok, ^volume}, Volumes.inspect(__MODULE__, key)) end
    )
  end

  @doc false
  def retry_admission(call, unchanged?, remaining \\ 100) do
    case call.() do
      {:error, %SmolBox.Error{category: :admission_exhausted, evidence: :not_dispatched}} =
          rejected
      when remaining > 0 ->
        if unchanged?.() do
          Process.sleep(10)
          retry_admission(call, unchanged?, remaining - 1)
        else
          rejected
        end

      result ->
        result
    end
  end

  defp create(c, id, readonly) do
    spec = specification(c, id, readonly)

    {:ok, key} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = idle(key)
    checkpoint(c, id <> "-created")
    key
  end

  defp specification(c, id, readonly) do
    {:ok, mount} = VolumeMount.new("data", "/mnt/volumes/data", readonly: readonly)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: c.scope,
        id: id,
        artifact: c.artifact,
        profile: c.profile,
        volumes: [mount]
      )

    spec
  end

  defp command(c, id, script) do
    {:ok, command} = Command.new(["/bin/sh", "-c", script], workdir: "/workspace")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: c.scope,
        id: id,
        artifact: c.artifact,
        profile: c.profile,
        command: command
      )

    spec
  end

  defp completed(machine, spec, code) do
    {:ok, key} = Machines.submit(__MODULE__, machine, spec)

    {:ok, %{state: :completed, result: %{exit_code: ^code}}} =
      SmolBox.await(__MODULE__, key, 180_000)

    %{state: :running} = idle(machine)
    key
  end

  defp read(c, machine, id, bytes) do
    spec = command(c, id, "test -f /mnt/volumes/data/kept.bin")

    output = %{
      "destination" => "kept",
      "path" => "/mnt/volumes/data/kept.bin",
      "max_bytes" => 131_072
    }

    key = completed(machine, %{spec | outputs: [output]}, 0)
    {:ok, ^bytes} = Directory.read_output(c.objects, key, "kept", 131_072)
  end

  defp idle(key) do
    {:ok, record} = Machines.await(__MODULE__, key, 180_000)
    record
  end

  defp lifecycle(key, operation, state, retries \\ 10) do
    record = idle(key)

    case apply(Machines, operation, [__MODULE__, key, record.version]) do
      {:ok, _} ->
        %{state: ^state} = idle(key)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle(key, operation, state, retries - 1)

      error ->
        raise "ordinary lifecycle admission failed: #{inspect(error)}"
    end
  end

  defp ready(c) do
    deadline = System.monotonic_time(:millisecond) + 180_000

    wait(
      fn ->
        {:ok, workers} = SmolBox.workers(__MODULE__)
        Enum.any?(workers, &(&1.id == c.target.id and &1.health_status == :ready))
      end,
      deadline
    )
  end

  defp wait(check, deadline) do
    unless check.() do
      true = System.monotonic_time(:millisecond) < deadline
      Process.sleep(50)
      wait(check, deadline)
    end
  end

  defp usage(c, slots, disk) do
    {adapter, store} = c.store
    {:ok, value} = adapter.usage(store, c.target.id)
    true = value.slots == slots and value.disk_gb == disk
  end

  defp checkpoint(c, label) do
    records = records(c, nil, 0) |> Enum.filter(&(&1.scope == c.scope))

    values =
      Enum.map(records, fn record ->
        {:ok, bytes} = Codec.encode(record)
        Base.encode64(bytes)
      end)

    save(c.root, "private-records-" <> label, values)
  end

  defp records(c, cursor, count) do
    {adapter, store} = c.store
    {:ok, page, next} = adapter.backend_assignments(store, c.target.id, cursor, 100)
    true = count + length(page) <= 1024
    if next, do: page ++ records(c, next, count + length(page)), else: page
  end

  defp save(root, name, value) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(value), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end

  def close(c) do
    usage(c, 0, 0)

    for id <- ~w(original readonly contender) do
      case Machines.inspect(__MODULE__, {c.scope, id}) do
        {:ok, %{state: :deleted}} -> :ok
        {:error, %{category: :not_found}} -> :ok
      end
    end

    for id <- ~w(data sibling rejected budget) do
      case Volumes.inspect(__MODULE__, {c.scope, id}) do
        {:ok, %{state: :deleted}} -> :ok
        {:error, %{category: :not_found}} -> :ok
      end
    end

    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    :ok
  end
end
