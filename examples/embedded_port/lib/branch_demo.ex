defmodule SmolBox.Example.EmbeddedBranches do
  @moduledoc """
  Opt-in ordinary Linux/macOS local-bare branch acceptance through public managed APIs.
  Uses the real store adapter and retains the original Runtime and store after
  failure. The private control file permits explicit ordinary cleanup or normal
  disk-preserving shutdown; it never signals, adopts or replays a native owner.
  """
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Backend.{EmbeddedContext, Reference}
  alias SmolBox.Embedded.Config
  alias SmolBox.Example.EmbeddedBranchControl
  alias SmolBox.Runtime.{NativeAuthority, Target}
  alias SmolBox.Store.{Codec, Memory}

  alias SmolBox.{
    Branches,
    BranchPolicy,
    BranchSpec,
    Checkpoint,
    CheckpointCaptureSpec,
    CheckpointPolicy,
    CheckpointResult,
    Checkpoints,
    Command,
    ExecutionSpec,
    Machines,
    ManagedMachineSpec,
    Profile
  }

  @ids ~w(source first held)

  def configure(%Config{platform: platform} = target, options \\ [])
      when platform in [:linux, :macos] do
    {:ok, profile} =
      Profile.new("public-branches-offline",
        cpus: 1,
        memory_mb: 512,
        host_overhead_mb: 128,
        preparation_ms: 120_000,
        execution_ms: 30_000,
        max_output_bytes: 8192,
        max_file_bytes: 131_072
      )

    {:ok, policy} =
      BranchPolicy.new(
        id: "ordinary-branches",
        resources: %{slots: 1, cpus: 1, memory_mb: 640, disk_gb: 5}
      )

    target = %{
      target
      | profiles: [profile],
        branch_policies: [policy],
        allocation_floor: %{storage_gb: 1, overlay_gb: 1, host_overhead_mb: 128},
        capacity: %{slots: 5, cpus: 5, memory_mb: 3200, disk_gb: 16}
    }

    target =
      case Keyword.fetch(options, :capture_root) do
        :error ->
          target

        {:ok, root} ->
          {:ok, policy} =
            CheckpointPolicy.new(
              id: "ordinary-capture",
              root: root,
              max_bytes: 536_870_912,
              resources: %{slots: 1, cpus: 1, memory_mb: 640, disk_gb: 8}
            )

          %{target | checkpoint_policies: [policy]}
      end

    target =
      case Keyword.fetch(options, :checkpoint_seed) do
        :error ->
          target

        {:ok, %{path: path, sha256: sha256}} ->
          {:ok, seed} =
            Checkpoint.new(
              id: "ordinary-seed",
              path: path,
              sha256: sha256,
              profile: profile,
              platform: target.platform,
              architecture: target.architecture,
              runtime_version: Config.sdk_version(target)
            )

          %{target | checkpoints: [seed]}
      end

    :ok = Config.validate(target)
    true = Config.sdk_identity(target)["feature_versions"]["branches"] == 1
    true = Config.sdk_identity(target)["feature_versions"]["checkpoints"] == 1
    target
  end

  def run(%Config{platform: platform} = target, output, options \\ [])
      when platform in [:linux, :macos] do
    Process.flag(:trap_exit, true)
    Process.put({__MODULE__, :closed}, false)
    Process.delete({__MODULE__, :owner})
    :ok = Config.validate(target)
    [approved_artifact] = target.artifacts

    artifact =
      if Keyword.get(options, :campaign, :branches) == :checkpoints do
        [seed] = target.checkpoints
        Checkpoint.artifact(seed)
      else
        Map.take(approved_artifact, ~w(id sha256 architecture))
      end

    [policy] = target.branch_policies
    scope = Keyword.get(options, :scope, "public-branches-proof")
    true = SmolBox.Validation.identifier?(scope)

    {children, store, mode} =
      case Keyword.fetch(options, :store) do
        {:ok, store} -> {[], store, Keyword.fetch!(options, :mode)}
        :error -> {[{Memory, name: __MODULE__.Store}], {Memory, __MODULE__.Store}, :ephemeral}
      end

    fingerprint =
      Keyword.get_lazy(options, :fingerprint_key, fn ->
        true = mode == :ephemeral
        :crypto.strong_rand_bytes(32)
      end)

    true = is_binary(fingerprint) and byte_size(fingerprint) == 32
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)
    objects_path = Path.join(output, "objects")
    :ok = File.mkdir(objects_path)
    :ok = File.chmod(objects_path, 0o700)
    {:ok, objects} = Directory.new(objects_path, max_file_bytes: 131_072)
    save(output, "private-fingerprint", Base.encode64(fingerprint))

    runtime_options = [
      name: __MODULE__,
      namespace: "portbranch",
      mode: mode,
      store: store,
      artifact_store: {Directory, objects},
      fingerprint_key: fingerprint,
      workers: [target],
      lease_ms: 1000,
      poll_ms: 50
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children ++ [{SmolBox, runtime_options}], strategy: :one_for_one)

    c = %{
      root: output,
      supervisor: supervisor,
      store: store,
      mode: mode,
      scope: scope,
      target: target,
      profile: hd(target.profiles),
      artifact: artifact,
      policy: policy,
      runtime_options: runtime_options,
      campaign: Keyword.get(options, :campaign, :branches)
    }

    try do
      evidence = if c.campaign == :checkpoints, do: exercise_checkpoints(c), else: exercise(c)
      :ok = close(c)
      {:ok, evidence}
    rescue
      error -> retain(c, error, __STACKTRACE__)
    catch
      kind, _ -> retain(c, kind, [])
    end
  end

  defp exercise_checkpoints(c) do
    ready(c, System.monotonic_time(:millisecond) + 180_000)
    remember_owner(c)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: c.scope,
        id: "source",
        artifact: c.artifact,
        profile: c.profile,
        checkpointable: true
      )

    {:ok, source} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = idle(source)
    lifecycle(source, :start, :running)

    command(
      c,
      "source",
      "prepare-capture",
      "set -eu; mkdir -p /workspace; printf source-disk > /workspace/smolbox-branch-disk; " <>
        "printf source-memory > /dev/shm/smolbox-branch-memory"
    )

    [policy] = c.target.checkpoint_policies

    {:ok, request} =
      CheckpointCaptureSpec.new(id: "prepared", policy: policy, idle: true, timeout_ms: 180_000)

    {:ok, handle} = Checkpoints.capture(__MODULE__, source, request)
    {:ok, ^handle} = Checkpoints.capture(__MODULE__, source, request)
    {:ok, %{state: :captured, result: result}} = Checkpoints.await(__MODULE__, handle, 180_000)
    checkpoint(c, "captured")
    {:ok, current} = Machines.inspect(__MODULE__, source)

    {:ok, %{state: :completed}} =
      Checkpoints.resolve(__MODULE__, handle, current.version, quiesced: true)

    capture_usage(c, 1, 1)
    data(c, "source", "after-capture", "source", true)
    lifecycle(source, :stop, :stopped)

    {:ok, approval} =
      CheckpointResult.approval(result, id: "ordinary-prepared", worker_path: result.path)

    true = digest_file(result.path) == result.sha256
    checkpoint(c, "before-replacement")
    c = replace_stopped(c, %{c.target | checkpoints: c.target.checkpoints ++ [approval]})

    for id <- ~w(first held) do
      {:ok, key} = Checkpoints.restore(__MODULE__, handle, approval, scope: c.scope, id: id)
      %{state: :stopped} = idle(key)
      lifecycle(key, :start, :running)
      data(c, id, "restored", "source", true)
    end

    capture_usage(c, 3, 1)

    command(
      c,
      "first",
      "change-restored",
      "printf first-disk > /workspace/smolbox-branch-disk; printf first-memory > /dev/shm/smolbox-branch-memory"
    )

    data(c, "first", "changed", "first", true)
    data(c, "held", "independent", "source", true)
    true = digest_file(result.path) == result.sha256
    lifecycle({c.scope, "first"}, :stop, :stopped)
    lifecycle({c.scope, "first"}, :start, :running)
    data(c, "first", "cold", "first", false)
    checkpoint(c, "restored")
    delete({c.scope, "first"})
    delete({c.scope, "held"})
    lifecycle(source, :delete, :deleted)
    capture_usage(c, 0, 1)
    true = digest_file(result.path) == result.sha256
    :ok = File.rm(result.path)
    {:ok, _} = Checkpoints.release(__MODULE__, handle, artifacts_removed: true)
    capture_usage(c, 0, 0)
    backing_absent(c)
    checkpoint(c, "completed")

    %{
      campaign: "ordinary-public-native-checkpoints",
      package_manifest_sha256: c.target.package_manifest_sha256,
      store_mode: c.mode,
      capture_source_continues: true,
      duplicate_capture_retained: true,
      stopped_runtime_replacement: true,
      ram_and_disk_restored: true,
      independent_restores: 2,
      cold_restart_does_not_restore_ram: true,
      captured_bytes_unchanged: true,
      capture_artifact_removed: true,
      native_capture_cleanup: true,
      codec_roundtrips: true,
      owned_deleted: true,
      final_reserved_slots: 0,
      final_reserved_disk_gb: 0,
      deliberate_process_interruption: false,
      crash_handling_qualified: false
    }
  end

  defp digest_file(path) do
    File.stream!(path, 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp capture_usage(c, machines, retained) do
    {adapter, context} = c.store
    {:ok, actual} = adapter.usage(context, c.target.id)

    expected =
      Map.new(Profile.resources(c.profile), fn {key, value} ->
        {key, value * machines + if(key == :disk_gb, do: retained, else: 0)}
      end)

    true = actual == expected
  end

  defp replace_stopped(c, target) do
    :ok = Config.validate(target)
    %{state: :stopped} = idle({c.scope, "source"})
    context = Process.get({__MODULE__, :owner})
    bridge = EmbeddedContext.bridge(context)
    epoch = context.epoch

    :ok =
      shutdown_authority(
        SmolBox.Runtime.coordinator(__MODULE__),
        c.target.id,
        System.monotonic_time(:millisecond) + c.target.limits.shutdown_ms + 1000,
        fn ->
          {:ok, %{epoch: ^epoch}} = bridge.health(context.server)
          :ok = bridge.shutdown(context.server)

          await_stopped(
            bridge,
            context.server,
            System.monotonic_time(:millisecond) + c.target.limits.shutdown_ms
          )
        end
      )

    child = {SmolBox.Runtime, __MODULE__}
    :ok = Supervisor.terminate_child(c.supervisor, child)
    :ok = Supervisor.delete_child(c.supervisor, child)
    options = Keyword.put(c.runtime_options, :workers, [target])
    {:ok, _} = Supervisor.start_child(c.supervisor, {SmolBox, options})
    updated = %{c | target: target, runtime_options: options}
    ready(updated, System.monotonic_time(:millisecond) + 180_000)
    remember_owner(updated)
    updated
  end

  defp exercise(c) do
    ready(c, System.monotonic_time(:millisecond) + 180_000)
    remember_owner(c)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: c.scope,
        id: "source",
        artifact: c.artifact,
        profile: c.profile,
        checkpointable: true
      )

    {:ok, source} = Machines.create(__MODULE__, spec)
    %{state: :stopped} = idle(source)
    usage(c, 1, 0)
    lifecycle(source, :start, :running)

    command(
      c,
      "source",
      "setup",
      "set -eu; mkdir -p /workspace; " <>
        "printf source-disk > /workspace/smolbox-branch-disk; " <>
        "printf source-memory > /dev/shm/smolbox-branch-memory; " <>
        "command -v smolvm-branch-ready >/dev/null; " <>
        "smolvm-branch-ready </dev/null >/tmp/smolbox-branch-ready.log 2>&1 &"
    )

    first = create_child(c, "first", false)
    usage(c, 2, 1)
    blocked_source(c)
    :ok = SmolBox.drain_worker(__MODULE__, c.target.id)
    {:ok, blocked} = BranchSpec.new(id: "drained", policy: c.policy, idle: true)

    {:error,
     %{category: :admission_exhausted, operation: :worker_control, evidence: :not_dispatched}} =
      Branches.create(__MODULE__, source, blocked)

    usage(c, 2, 1)
    {:ok, maintenance} = SmolBox.worker_maintenance(__MODULE__, c.target.id)

    {:ok, %{mode: :active}} =
      SmolBox.resume_worker(__MODULE__, c.target.id, maintenance.control.version)

    held = create_child(c, "held", true)
    usage(c, 3, 2)
    {:ok, over_budget} = BranchSpec.new(id: "budget", policy: c.policy, idle: true)
    {:error, %{category: :admission_exhausted}} = Branches.create(__MODULE__, source, over_budget)
    usage(c, 3, 2)
    data(c, "source", "original", "source", true)
    data(c, "first", "inherited", "source", true)

    command(
      c,
      "first",
      "write-first",
      "printf first-disk > /workspace/smolbox-branch-disk; " <>
        "printf first-memory > /dev/shm/smolbox-branch-memory"
    )

    current = idle(held)
    {:error, _} = Machines.stop(__MODULE__, held, current.version)
    {:ok, _} = Branches.release(__MODULE__, held, current.version)
    {:ok, %{branch: %{state: :released}}} = Branches.await(__MODULE__, held, 180_000)
    {:ok, _} = Branches.release(__MODULE__, held, current.version)
    data(c, "held", "inherited", "source", true)

    command(
      c,
      "held",
      "write-held",
      "printf held-disk > /workspace/smolbox-branch-disk; " <>
        "printf held-memory > /dev/shm/smolbox-branch-memory"
    )

    independent(c, "before-restart")
    checkpoint(c, "both-children")
    lifecycle(first, :stop, :stopped)
    lifecycle(first, :start, :running)
    data(c, "first", "cold", "first", false)
    data(c, "source", "after-restart", "source", true)
    data(c, "held", "after-restart", "held", true)
    delete(first)
    usage(c, 2, 2)
    {:ok, %{branch: %{state: :retired}}} = Branches.retire(__MODULE__, first, quiesced: true)
    usage(c, 2, 2)
    {:error, _} = Branches.release_storage(__MODULE__, first, backing_removed: true)
    blocked_source(c)
    delete(held)
    usage(c, 1, 2)
    {:ok, %{branch: %{state: :retired}}} = Branches.retire(__MODULE__, held, quiesced: true)
    usage(c, 1, 2)
    checkpoint(c, "retired")
    delete(source)
    usage(c, 0, 2)
    backing_absent(c)
    {:ok, _} = Branches.release_storage(__MODULE__, first, backing_removed: true)
    usage(c, 0, 1)
    {:ok, _} = Branches.release_storage(__MODULE__, held, backing_removed: true)
    usage(c, 0, 0)
    checkpoint(c, "completed")

    %{
      campaign: "ordinary-public-native-branches",
      package_manifest_sha256: c.target.package_manifest_sha256,
      store_mode: c.mode,
      source_and_two_children_independent: true,
      held_release: true,
      duplicate_release_retained: true,
      cold_restart_does_not_restore_ram: true,
      source_dependencies_retired: 2,
      native_backing_acknowledgements: 2,
      branch_budget_rejected_before_dispatch: true,
      drain_rejected_new_branch: true,
      codec_roundtrips: true,
      owned_deleted: true,
      final_reserved_slots: 0,
      final_reserved_disk_gb: 0,
      deliberate_process_interruption: false,
      crash_handling_qualified: false
    }
  end

  defp create_child(c, id, hold) do
    {:ok, spec} = BranchSpec.new(id: id, policy: c.policy, idle: true, hold: hold)
    {:ok, key} = Branches.create(__MODULE__, {c.scope, "source"}, spec)
    {:ok, child} = Branches.await(__MODULE__, key, 180_000)
    true = child.branch.state == if(hold, do: :held, else: :ready)
    {:ok, ^key} = Branches.create(__MODULE__, {c.scope, "source"}, spec)
    idle(key)
    key
  end

  defp independent(c, label) do
    for {id, value} <- [{"source", "source"}, {"first", "first"}, {"held", "held"}],
        do: data(c, id, label, value, true)
  end

  defp data(c, id, label, value, ram) do
    script = "test \"$(cat /workspace/smolbox-branch-disk)\" = " <> value <> "-disk; "

    script =
      script <>
        if(ram,
          do: "test \"$(cat /dev/shm/smolbox-branch-memory)\" = " <> value <> "-memory",
          else: "test ! -e /dev/shm/smolbox-branch-memory"
        )

    command(c, id, id <> "-" <> label, "set -eu; " <> script)
  end

  defp command(c, id, label, script) do
    {:ok, machine} = Machines.inspect(__MODULE__, {c.scope, id})
    {:ok, cmd} = Command.new(["/bin/sh", "-c", script], workdir: "/workspace")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: c.scope,
        id: label,
        artifact: machine.spec.artifact,
        profile: c.profile,
        command: cmd
      )

    {:ok, key} = Machines.submit(__MODULE__, {c.scope, id}, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stderr: ""}}} =
      SmolBox.await(__MODULE__, key, 180_000)

    %{state: :running} = idle({c.scope, id})
  end

  defp blocked_source(c) do
    record = idle({c.scope, "source"})

    for action <- [:start, :stop, :delete],
        do:
          {:error, _} = apply(Machines, action, [__MODULE__, {c.scope, "source"}, record.version])

    %{state: :running} = idle({c.scope, "source"})
  end

  defp delete(key) do
    %{state: :running} = idle(key)
    lifecycle(key, :stop, :stopped)
    lifecycle(key, :delete, :deleted)
  end

  defp lifecycle(key, action, desired, retries \\ 10) do
    current = idle(key)

    case apply(Machines, action, [__MODULE__, key, current.version]) do
      {:ok, _} ->
        %{state: ^desired} = idle(key)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle(key, action, desired, retries - 1)

      {:error, error} ->
        raise "ordinary branch lifecycle rejected: #{inspect(error.category)}"
    end
  end

  defp idle(key) do
    {:ok, record} = Machines.await(__MODULE__, key, 180_000)
    record
  end

  defp ready(c, deadline) do
    {:ok, workers} = SmolBox.workers(__MODULE__)

    unless Enum.any?(workers, &(&1.id == c.target.id and &1.health_status == :ready)) do
      true = System.monotonic_time(:millisecond) < deadline
      Process.sleep(50)
      ready(c, deadline)
    end
  end

  @doc false
  def expected_usage(profile, policy, ordinary, extra) do
    Map.merge(Profile.resources(profile), policy.resources, fn _key, one, additional ->
      one * ordinary + additional * extra
    end)
  end

  defp usage(c, ordinary, extra) do
    {adapter, context} = c.store
    {:ok, actual} = adapter.usage(context, c.target.id)
    true = actual == expected_usage(c.profile, c.policy, ordinary, extra)
  end

  defp backing_absent(c) do
    for id <- @ids do
      {:ok, record} = Machines.inspect(__MODULE__, {c.scope, id})

      name =
        :crypto.hash(:sha256, record.machine_name)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      path = backing_path(System.user_home!(), c.target.platform, name)
      {:error, :enoent} = File.lstat(path)
    end
  end

  @doc false
  def backing_path(home, platform, name) when platform in [:linux, :macos] do
    cache =
      if platform == :macos,
        do: Path.join(home, "Library/Caches"),
        else: Path.join(home, ".cache")

    Path.join([cache, "smolvm", "vms", name])
  end

  @doc false
  def checkpoint(c, label) do
    values =
      records(c, nil, 0)
      |> Enum.filter(&(&1.scope == c.scope))
      |> Enum.map(fn record ->
        {:ok, bytes} = Codec.encode(record)
        {:ok, ^record} = Codec.decode(bytes)
        Base.encode64(bytes)
      end)

    save(c.root, "private-records-" <> label, values)
  end

  defp records(c, cursor, count) do
    {adapter, context} = c.store
    {:ok, page, next} = adapter.backend_assignments(context, c.target.id, cursor, 100)
    true = count + length(page) <= 1024
    if next, do: page ++ records(c, next, count + length(page)), else: page
  end

  defp retain(c, error, stack) do
    try do
      diagnostic =
        case error do
          %MatchError{term: {:error, %SmolBox.Error{} = rejection}} ->
            Map.take(rejection, [:category, :operation, :evidence])

          _ ->
            %{}
        end

      frames =
        Enum.take(stack, 8)
        |> Enum.map(fn {module, function, args, loc} ->
          %{
            module: Atom.to_string(module),
            function: Atom.to_string(function),
            arity: if(is_list(args), do: length(args), else: args),
            line: loc[:line]
          }
        end)

      save(c.root, "failure", %{rejected: diagnostic, frames: frames})
      checkpoint(c, "failure")
    rescue
      _ -> :diagnostic_unavailable
    catch
      _, _ -> :diagnostic_unavailable
    end

    unless Process.get({__MODULE__, :closed}), do: EmbeddedBranchControl.wait(c)
    {:error, :qualification_failed}
  end

  def close(c) do
    usage(c, 0, 0)

    for id <- @ids do
      case Machines.inspect(__MODULE__, {c.scope, id}) do
        {:ok, %{state: :deleted}} -> :ok
        {:error, %{category: :not_found}} -> :ok
      end
    end

    shutdown(c)
  end

  @doc false
  def shutdown(c) do
    context = Process.get({__MODULE__, :owner}) || remember_owner(c)
    bridge = EmbeddedContext.bridge(context)
    epoch = context.epoch
    deadline = System.monotonic_time(:millisecond) + c.target.limits.shutdown_ms + 1000

    :ok =
      shutdown_authority(SmolBox.Runtime.coordinator(__MODULE__), c.target.id, deadline, fn ->
        {:ok, %{epoch: ^epoch}} = bridge.health(context.server)
        true = System.monotonic_time(:millisecond) < deadline
        :ok = bridge.shutdown(context.server)

        await_stopped(bridge, context.server, deadline)
      end)

    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    :ok
  end

  @doc false
  def shutdown_authority(coordinator, id, deadline, function) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error,
       %SmolBox.Error{category: :expired, operation: :reconcile, evidence: :not_dispatched}}
    else
      # Tag every entered callback result, including errors. Only rejection of
      # authority acquisition itself may wait; shutdown is never replayed here.
      case enter_shutdown(coordinator, id, function) do
        {:entered, result} ->
          result

        {:error,
         %SmolBox.Error{
           category: :admission_exhausted,
           operation: :reconcile,
           evidence: :not_dispatched
         }} ->
          Process.sleep(min(25, max(0, deadline - System.monotonic_time(:millisecond))))
          shutdown_authority(coordinator, id, deadline, function)

        result ->
          result
      end
    end
  end

  defp enter_shutdown(coordinator, id, function),
    do: NativeAuthority.run(coordinator, id, fn -> {:entered, function.()} end)

  defp remember_owner(c) do
    {:ok, config} = GenServer.call(SmolBox.Runtime.coordinator(__MODULE__), :config)
    target = Enum.find(config.workers, &(&1.id == c.target.id)) |> Target.pin()
    %Reference{context: context} = target.connection
    true = is_pid(context.server) and is_binary(context.epoch)
    Process.put({__MODULE__, :owner}, context)
    context
  end

  @doc false
  def await_stopped(bridge, server, deadline) do
    {:ok, health} = bridge.health(server)

    case health.status do
      :stopped ->
        :ok

      status when status in [:closing, :unavailable] ->
        true = System.monotonic_time(:millisecond) < deadline
        Process.sleep(25)
        await_stopped(bridge, server, deadline)
    end
  end

  @doc false
  def save(root, name, value) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(value), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end
