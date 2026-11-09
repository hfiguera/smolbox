Code.require_file(Path.join(__DIR__, "owned_control.ex"))

defmodule SmolBox.Example.EmbeddedGrowth do
  @moduledoc """
  Explicit ordinary unmounted stop-grow-start acceptance for an approved Linux
  Port target. Memory supports :single; durable adapters support :prepare/:resume
  in separate normally exited BEAMs with stable store keys and artifact storage.
  Failures retain the original owner for exact-version control and explicit
  growth resolution. No uncertain resize is retried and no fault is injected.
  """
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Embedded.{Config, GrowthTransition, NativeGrowth, RegistryPolicy}
  alias SmolBox.Example.{EmbeddedGrowthControl, EmbeddedOwnedControl}
  alias SmolBox.Store.{Codec, Memory}

  alias SmolBox.{
    Command,
    ExecutionSpec,
    Files,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Runtime,
    Source,
    Validation
  }

  def read_settings!(path) do
    true = is_binary(path) and Path.type(path) == :absolute
    info = File.lstat!(path)
    {uid, 0} = System.cmd(System.find_executable("id"), ["-u"])

    true =
      info.type == :regular and info.uid == String.to_integer(String.trim(uid)) and
        info.size <= 65_536 and Bitwise.band(info.mode, 0o077) == 0

    File.open!(path, [:read, :binary], fn stream ->
      bytes = IO.binread(stream, 65_537)
      true = is_binary(bytes) and byte_size(bytes) <= 65_536
      settings = Jason.decode!(bytes)
      true = is_map(settings)
      settings
    end)
  end

  def configure_settings(%Config{} = target, settings) do
    true =
      is_map(settings) and
        Map.keys(settings) -- ~w(artifact_id source_id sources network cache_policy) == []

    sources = Map.get(settings, "sources", [])
    true = Validation.list?(sources, 32)
    sources = Enum.map(sources, &approved_source/1)
    true = MapSet.size(MapSet.new(sources, & &1.id)) == length(sources)
    additions = Enum.reject(sources, &(&1 in target.sources))
    registry = cache_policy(settings, target.registry_policy)
    target = %{target | sources: target.sources ++ additions, registry_policy: registry}
    target = configure(target, network: network(settings))

    selection =
      for {key, option} <- [{"artifact_id", :artifact_id}, {"source_id", :source_id}],
          Map.has_key?(settings, key),
          do: {option, Map.fetch!(settings, key)}

    input = select_input(target, selection)
    true = input["kind"] != "oci" or hd(target.profiles).network != :offline
    {target, selection}
  end

  defp approved_source(%{"kind" => kind} = value) when kind in ["oci", "registry"] do
    keys = ~w(kind id reference architecture)
    keys = if kind == "registry", do: keys ++ ~w(content_sha256 credential_ref), else: keys
    true = Map.keys(value) -- keys == []

    options = [
      id: value["id"],
      reference: value["reference"],
      architecture: value["architecture"]
    ]

    {:ok, source} =
      if kind == "oci",
        do: Source.oci(options),
        else:
          Source.registry(
            options ++
              [content_sha256: value["content_sha256"], credential_ref: value["credential_ref"]]
          )

    source
  end

  defp network(%{"network" => %{"hosts" => hosts, "cidrs" => cidrs} = policy}) do
    true = Enum.sort(Map.keys(policy)) == ~w(cidrs hosts)
    {:ok, network} = NetworkPolicy.new(hosts: hosts, cidrs: cidrs)
    network
  end

  defp network(settings) do
    false = Map.has_key?(settings, "network")
    :offline
  end

  defp cache_policy(%{"cache_policy" => policy}, existing) do
    true =
      is_map(policy) and
        Map.keys(policy) --
          ~w(max_download_bytes max_cache_bytes max_cache_files token_realms) == []

    {:ok, registry} =
      RegistryPolicy.new(
        max_download_bytes: policy["max_download_bytes"],
        max_cache_bytes: policy["max_cache_bytes"],
        max_cache_files: policy["max_cache_files"],
        token_realms: Map.get(policy, "token_realms", %{})
      )

    true = existing == nil or existing == registry
    registry
  end

  defp cache_policy(_settings, existing), do: existing

  def configure(%Config{platform: :linux} = target, options \\ []) do
    true = Validation.keys?(options, [:network])
    network = Keyword.get(options, :network, :offline)

    profile_id =
      if network == :offline, do: "public-growth-offline", else: "public-growth-network"

    {:ok, profile} =
      Profile.new(profile_id,
        cpus: 1,
        memory_mb: 512,
        network: network,
        preparation_ms: 120_000,
        execution_ms: 30_000,
        max_file_bytes: 131_072
      )

    target = %{
      target
      | profiles: [profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 8}
    }

    :ok = Config.validate(target)
    true = Config.sdk_identity(target)["feature_versions"]["disk_growth"] == 1

    true =
      network == :offline or Config.sdk_identity(target)["feature_versions"]["networking"] == 1

    target
  end

  def run(%Config{platform: :linux} = target, output, options \\ []) do
    Process.flag(:trap_exit, true)
    Process.put({__MODULE__, :closed}, false)
    phase = Keyword.get(options, :phase, :single)
    scope = Keyword.get(options, :scope, "public-growth-proof")
    true = phase in [:single, :prepare, :resume] and SmolBox.Validation.identifier?(scope)
    :ok = Config.validate(target)
    artifact = select_input(target, options)
    true = artifact["kind"] != "oci" or hd(target.profiles).network != :offline
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
      namespace: "portgrow",
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
      artifact: artifact,
      store: store,
      mode: mode,
      phase: phase,
      scope: scope
    }

    try do
      result = execute(c, expected)

      evidence =
        Map.merge(result, %{
          scope: "public-linux-growth-runtime",
          phase: phase,
          package_manifest_sha256: target.package_manifest_sha256,
          identity: target.package_identity,
          fixture_sha256: if(c.artifact["kind"] == nil, do: c.artifact["sha256"], else: nil),
          creation_input: c.artifact,
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

  @doc false
  def select_input(%Config{} = target, options \\ []) do
    local = Keyword.get(options, :artifact_id)
    remote = Keyword.get(options, :source_id)

    cond do
      is_nil(remote) -> select_artifact(target.artifacts, local)
      not is_nil(local) -> raise ArgumentError, "select either an artifact or a source"
      true -> select_source(target.sources, remote)
    end
  end

  @doc false
  def select_source(sources, id) when is_list(sources) do
    matches = if is_binary(id), do: Enum.filter(sources, &(&1.id == id)), else: []

    case matches do
      [%Source{kind: kind} = source] when kind in [:oci, :registry] -> Source.artifact(source)
      _ -> raise ArgumentError, "select exactly one approved remote source by id"
    end
  end

  @doc false
  def select_artifact(artifacts, selected_id \\ nil) when is_list(artifacts) do
    matches =
      case {artifacts, selected_id} do
        {[artifact], nil} -> [artifact]
        {catalog, id} when is_binary(id) -> Enum.filter(catalog, &(&1["id"] == id))
        _ -> []
      end

    case matches do
      [artifact] -> Map.take(artifact, ~w(id sha256 architecture))
      _ -> raise ArgumentError, "select exactly one approved artifact by id"
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
    true = held.disk_sizes == %{storage_gb: 2, overlay_gb: 3}
    usage(c, 1, 5)
    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    %{prepared_stopped: true, owned_deleted: false, reserved_slots: 1, reserved_disk_gb: 5}
  end

  defp execute(%{phase: :resume} = c, expected) do
    ready(c)
    original = Enum.find(expected, &match?(%SmolBox.ManagedMachine{id: "original"}, &1))
    %{state: :stopped} = current = idle({c.scope, "original"})
    true = original.scope == c.scope
    same_authority(original, current)
    {:ok, kept} = Directory.read_output(c.objects, {c.scope, "first-read"}, "kept", 131_072)
    true = kept == data()
    result = resume(c, original)
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

    unless Process.get({__MODULE__, :closed}), do: EmbeddedGrowthControl.wait(c, &close/1)
    {:error, :qualification_failed}
  end

  defp prepare(c) do
    ready(c)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: c.scope,
        id: "original",
        artifact: c.artifact,
        profile: c.profile
      )

    {:ok, key} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = created = idle(key)
    usage(c, 1, 2)
    lifecycle(key, :start, :running)
    bytes = data()
    :ok = Directory.seed(c.objects, c.scope, "input", bytes)

    input = %{
      "source" => "input",
      "path" => "/workspace/in.bin",
      "size" => byte_size(bytes),
      "sha256" => Files.sha256(bytes),
      "mode" => "runtime_default"
    }

    write = command(c, "write", "cat /workspace/in.bin > /workspace/kept.bin; exit 7")
    completed(key, %{write | inputs: [input]}, 7)
    read(c, key, "first-read", bytes)
    workspace(c, key, "baseline-space", 0, 1_200_000_000)

    {:error, %{category: :admission_exhausted, evidence: :not_dispatched}} =
      expand(key, "running", storage_gb: 2)

    %{disk_expansions: history} = idle(key)
    true = history == %{}
    lifecycle(key, :stop, :stopped)

    {:error, %{category: :admission_exhausted, evidence: :not_dispatched}} =
      expand(key, "budget", storage_gb: 8, overlay_gb: 3)

    %{disk_expansions: history} = idle(key)
    true = history == %{}
    usage(c, 1, 2)

    grown = grow(c, key, "first", storage_gb: 2, overlay_gb: 3)
    true = grown.created_machine == created.created_machine
    true = grown.spec == created.spec and grown.fingerprint == created.fingerprint
    true = grown.backend_assignment == created.backend_assignment
    usage(c, 1, 5)
    duplicate(key, grown, "first")

    {:error, %{category: :identity_conflict, evidence: :not_dispatched}} =
      Machines.expand_disks(
        __MODULE__,
        key,
        "first",
        grown.disk_expansions["first"].requested_version,
        storage_gb: 3,
        overlay_gb: 3
      )

    lifecycle(key, :start, :running)
    read(c, key, "after-first-growth", bytes)
    workspace(c, key, "first-grown-space", 1_500_000_000, 2_200_000_000)
    lifecycle(key, :stop, :stopped)
    :ok = SmolBox.drain_worker(__MODULE__, c.target.id)

    {:error, %{category: :admission_exhausted, evidence: :not_dispatched}} =
      expand(key, "draining", storage_gb: 3)

    after_drain = idle(key)
    true = after_drain.disk_expansions == grown.disk_expansions
    usage(c, 1, 5)
    checkpoint(c, "before-replacement")
    after_drain
  end

  defp resume(c, held) do
    key = {c.scope, "original"}
    ready(c)
    %{state: :stopped} = current = idle(key)
    same_authority(held, current)
    usage(c, 1, 5)
    {:ok, maintenance} = SmolBox.worker_maintenance(__MODULE__, c.target.id)
    true = maintenance.control.mode == :draining
    duplicate(key, current, "first")

    {:ok, %{mode: :active}} =
      SmolBox.resume_worker(__MODULE__, c.target.id, maintenance.control.version)

    lifecycle(key, :start, :running)
    read(c, key, "after-replacement", data())

    completed(
      key,
      command(c, "new-write", "printf new > /workspace/new.bin; test -s /workspace/new.bin"),
      0
    )

    lifecycle(key, :stop, :stopped)
    second = grow(c, key, "second", storage_gb: 3)
    true = second.disk_sizes == %{storage_gb: 3, overlay_gb: 3}
    first = second.disk_expansions["first"].native_transition
    next = second.disk_expansions["second"].native_transition
    true = next.previous == first.receipt
    usage(c, 1, 6)
    lifecycle(key, :start, :running)
    read(c, key, "after-second-growth", data())
    workspace(c, key, "second-grown-space", 2_500_000_000, 3_300_000_000)

    completed(
      key,
      command(c, "new-write-retained", ~s|test "$(cat /workspace/new.bin)" = new|),
      0
    )

    {:ok, measured} = Machines.measurements(__MODULE__, key)
    true = measured.machine.storage_gb == 3 and measured.machine.overlay_gb == 3
    lifecycle(key, :stop, :stopped)
    lifecycle(key, :delete, :deleted)
    deleted = idle(key)
    duplicate(key, deleted, "first")
    duplicate(key, deleted, "second")
    usage(c, 0, 0)
    checkpoint(c, "completed")

    %{
      file_bytes: byte_size(data()),
      file_sha256: Files.sha256(data()),
      stopped_runtime_replacement: true,
      growth_history_retained: true,
      immutable_creation_retained: true,
      growth_budget_rejected_before_dispatch: true,
      running_growth_rejected: true,
      drain_retained: true,
      duplicate_growth_retained: true,
      conflicting_growth_rejected: true,
      storage_filesystem_growth: true,
      overlay_geometry_verified: true,
      omitted_target_retained: true,
      material_chain_retained: true,
      owned_deleted: true,
      final_reserved_slots: 0,
      final_reserved_disk_gb: 0
    }
  end

  defp same_authority(before, current) do
    for field <- [
          :spec,
          :fingerprint,
          :created_machine,
          :backend_assignment,
          :disk_sizes,
          :disk_expansions
        ] do
      true = Map.fetch!(before, field) == Map.fetch!(current, field)
    end

    true = NativeGrowth.record_valid?(current)
  end

  defp grow(c, key, id, targets) do
    {:ok, _} = expand(key, id, targets)
    %{state: :stopped} = grown = idle(key)
    %{state: :completed, native_transition: transition} = grown.disk_expansions[id]
    true = GrowthTransition.valid?(transition) and NativeGrowth.record_valid?(grown)
    {:ok, encoded} = Codec.encode(grown)
    {:ok, decoded} = Codec.decode(encoded)
    true = decoded == grown
    checkpoint(c, id <> "-completed")
    grown
  end

  defp expand(key, id, targets) do
    retry_version(
      idle(key),
      fn record -> Machines.expand_disks(__MODULE__, key, id, record.version, targets) end,
      fn -> idle(key) end
    )
  end

  # A fresh observation may replace only an unchanged record's lease/version
  # metadata, and only after an explicit pre-dispatch stale-version rejection.
  # Accepted work, uncertainty and changed material are never resubmitted.
  @doc false
  def retry_version(record, call, fetch, remaining \\ 10) do
    case call.(record) do
      {:error, %SmolBox.Error{category: :stale_version, evidence: :not_dispatched}} = rejected
      when remaining > 0 ->
        current = fetch.()

        if current.version > record.version and
             admission_snapshot(record) == admission_snapshot(current),
           do: retry_version(current, call, fetch, remaining - 1),
           else: rejected

      result ->
        result
    end
  end

  defp admission_snapshot(record) do
    Map.drop(record, [
      :version,
      :generation,
      :worker_generation,
      :claim_owner,
      :claim_until_ms,
      :updated_at_ms,
      :next_due_at_ms
    ])
  end

  defp duplicate(key, record, id) do
    expansion = record.disk_expansions[id]

    {:ok, repeated} =
      Machines.expand_disks(
        __MODULE__,
        key,
        id,
        expansion.requested_version,
        Map.to_list(expansion.request)
      )

    true = repeated.disk_expansions == record.disk_expansions
  end

  defp workspace(c, key, id, minimum, maximum) do
    cmd = workspace_command(minimum, maximum)
    spec = %{command(c, id, "true") | command: cmd}
    completed(key, spec, 0)
  end

  @doc false
  def workspace_command(minimum, maximum) do
    true = is_integer(minimum) and minimum >= 0 and is_integer(maximum) and maximum >= minimum

    # Both the approved BusyBox bare rootfs and the packed workload provide
    # these POSIX tools. There are at most eleven measurements and ten waits;
    # the enclosing managed command still enforces its absolute execution budget.
    script = """
    attempt=0
    while :; do
      report=$(LC_ALL=C df -Pk /workspace) || exit 1
      bytes=$(printf '%s\\n' "$report" | LC_ALL=C awk '
        NR == 2 && NF >= 6 && $2 ~ /^[0-9]+$/ && length($2) <= 12 {
          printf "%.0f\\n", $2 * 1024
          valid = 1
        }
        END { if (NR != 2 || !valid) exit 1 }
      ') || exit 1
      if [ "$bytes" -ge #{minimum} ]; then
        [ "$bytes" -le #{maximum} ] || exit 1
        printf 'workspace_bytes=%s\\n' "$bytes"
        exit 0
      fi
      [ "$attempt" -lt 10 ] || exit 1
      sleep 1 || exit 1
      attempt=$((attempt + 1))
    done
    """

    {:ok, cmd} = Command.new(["/bin/sh", "-c", script], workdir: "/workspace")
    cmd
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
    spec = command(c, id, "test -f /workspace/kept.bin")

    output = %{
      "destination" => "kept",
      "path" => "/workspace/kept.bin",
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

  @doc false
  def stop_owned(c, "original", version),
    do:
      EmbeddedOwnedControl.stop(
        __MODULE__,
        c.target.id,
        {c.scope, "original"},
        version
      )

  def close(c) do
    usage(c, 0, 0)

    case Machines.inspect(__MODULE__, {c.scope, "original"}) do
      {:ok, %{state: :deleted}} -> :ok
      {:error, %{category: :not_found}} -> :ok
    end

    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    :ok
  end
end
