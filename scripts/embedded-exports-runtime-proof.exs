defmodule SmolBox.ManagedExportProof do
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Embedded.{Config, RegistryPolicy}
  alias SmolBox.Store.{Codec, Memory}

  alias SmolBox.{
    Command,
    ExecutionSpec,
    ExportDestination,
    ExportResult,
    Exports,
    ExportSpec,
    Machines,
    ManagedMachineSpec,
    Source
  }

  @runtime __MODULE__.Runtime
  @store {Memory, __MODULE__.Store}
  @source {"public-export-proof", "source"}
  @copy {"public-export-proof", "copy"}
  @wait 180_000

  def fetch(path, "publication"), do: File.read(path)

  def run(["--without-rust", "--ordinary", "--readback", root, settings]) do
    without_rust!()
    {store, [], :durable} = store(["--postgres", settings])
    {:ok, objects} = Directory.new(Path.join(root, "objects"))
    key = root |> Path.join("private-fingerprint.json") |> File.read!() |> Jason.decode!()

    {:ok, runtime} =
      SmolBox.Runtime.start_link(
        runtime_options(store, :durable, objects, Base.decode64!(key), [])
      )

    try do
      {:ok, source} = Machines.inspect(@runtime, @source)
      {:ok, copy} = Machines.inspect(@runtime, @copy)
      ^source = archived(root, "deleted-source")
      ^copy = archived(root, "deleted-copy")
      %{state: :deleted, worker_id: worker, exports: %{"ordinary" => export}} = source
      %{state: :deleted} = copy
      {:ok, ^export} = Exports.fetch(@runtime, {elem(@source, 0), elem(@source, 1), "ordinary"})
      %{state: :completed, receipt: %{native_publication: %{schema: 1}}} = export
      {:ok, []} = SmolBox.workers(@runtime)
      {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} = usage(store, worker)

      save(root, "durable-readback", %{
        exact_machine_records: 2,
        exact_completed_export_receipt: true,
        native_workers: 0,
        final_reserved_slots: 0,
        crash_validation_deferred: true
      })
    after
      :ok = Supervisor.stop(runtime)
    end
  end

  def run([
        "--without-rust",
        "--ordinary",
        config_path,
        root,
        registry,
        token_path,
        mode | options
      ])
      when mode in ~w(bare container oci) do
    without_rust!()
    {store, store_children, store_mode} = store(options)
    %{type: :regular, size: size, mode: permissions} = File.lstat!(token_path)
    true = size in 1..16_384 and Bitwise.band(permissions, 0o077) == 0
    {config, _} = Code.eval_file(config_path)
    1 = get_in(Config.sdk_identity(config), ["feature_versions", "exports"])
    profile = hd(config.profiles)
    source_resources = SmolBox.Profile.resources(profile)
    staging_gib = max(64, 3 * profile.storage_gb) + source_resources.disk_gb
    export_resources = %{slots: 1, cpus: 4, memory_mb: 1152, disk_gb: staging_gib}

    {:ok, destination} =
      ExportDestination.new(
        id: "ordinary-export",
        registry: registry,
        repository: "proof/export",
        credential_ref: "publication",
        resources: export_resources,
        immutable_tags: true,
        allow_insecure_loopback: true
      )

    config = %{
      config
      | capacity:
          Map.merge(source_resources, export_resources, fn _, source, export ->
            source + export
          end),
        export_destinations: [destination],
        registry_credentials: {__MODULE__, token_path}
    }

    :ok = Config.validate(config)
    :ok = File.mkdir(root)
    :ok = File.chmod(root, 0o700)
    objects = Path.join(root, "objects")
    :ok = File.mkdir(objects)
    :ok = File.chmod(objects, 0o700)
    {:ok, objects} = Directory.new(objects)
    fingerprint_key = :crypto.strong_rand_bytes(32)
    save(root, "private-fingerprint", Base.encode64(fingerprint_key))

    child_options = runtime_options(store, store_mode, objects, fingerprint_key, [config])

    {:ok, supervisor} =
      Supervisor.start_link(
        store_children ++ [{SmolBox, child_options}],
        strategy: :one_for_one
      )

    try do
      ready(config.id)
      save(root, "ready", true)
      execute(config, destination, supervisor, child_options, root, mode)
      :ok = SmolBox.drain_worker(@runtime, config.id)
      :ok = Supervisor.stop(supervisor)
      save(root, "closed", true)
    rescue
      error ->
        try do
          save(root, "failure", %{
            exception: inspect(error.__struct__),
            line:
              Enum.find_value(__STACKTRACE__, fn
                {__MODULE__, _, _, location} -> location[:line]
                _ -> nil
              end)
          })

          for key <- [@source, @copy], {:ok, record} <- [Machines.inspect(@runtime, key)] do
            id = elem(key, 1)
            archive(root, "failure-" <> id, record)

            save(root, "failure-state-" <> id, %{
              machine: record.state,
              exports:
                Map.new(record.exports, fn {export_id, export} ->
                  {export_id,
                   %{
                     state: export.state,
                     category: export.error && export.error.category,
                     operation: export.error && export.error.operation,
                     evidence: export.error && export.error.evidence
                   }}
                end)
            })
          end
        after
          # Preserve the original Runtime and native owner for exact inspection.
          Process.sleep(:infinity)
        end
    end
  end

  defp execute(config, destination, supervisor, child_options, root, mode) do
    store = Keyword.fetch!(child_options, :store)

    artifact =
      if mode == "oci",
        do: Source.artifact(hd(config.sources)),
        else: Map.take(hd(config.artifacts), ~w(id sha256 architecture))

    profile = hd(config.profiles)
    source_spec = create(@source, artifact, profile)

    marker =
      if mode == "bare", do: "/workspace/smolbox-export-proof", else: "/app/smolbox-export-proof"

    command(
      @source,
      source_spec,
      "write",
      ["/bin/sh", "-c", "mkdir -p #{Path.dirname(marker)} && printf original > #{marker}"],
      ""
    )

    lifecycle(@source, :stop, :stopped)
    save(root, "source-stopped", true)

    {:ok, spec} = ExportSpec.new(id: "ordinary", destination: destination, tag: "ordinary-proof")
    {:ok, handle} = checked(root, "submit", Exports.submit(@runtime, @source, spec))
    save(root, "accepted", true)

    {:ok, %{state: :published, result: result, receipt: %{native_publication: publication}}} =
      checked(root, "await", Exports.await(@runtime, handle, 900_000))

    {:ok, ^handle} = Exports.submit(@runtime, @source, spec)
    {:ok, source} = ExportResult.source(result, id: "exported")
    true = source.content_sha256 == result.content_sha256
    {:ok, %{slots: 2}} = usage(store, config.id)
    {:ok, record} = Machines.inspect(@runtime, @source)
    archive(root, "published", record)
    save(root, "publication", publication.identity)

    {:ok, %{state: :completed, result: ^result}} =
      checked(root, "resolve", Exports.resolve(@runtime, handle, record.version, quiesced: true))

    {:ok, %{slots: 1}} = usage(store, config.id)
    archive(root, "completed", idle(@source))
    save(root, "resolved", true)

    {:ok, policy} =
      RegistryPolicy.new(
        max_download_bytes: 134_217_728,
        max_cache_bytes: 134_217_728,
        max_cache_files: 2
      )

    sources = if mode == "oci", do: Enum.uniq(config.sources ++ [source]), else: [source]
    config = %{config | sources: sources, registry_policy: policy}
    :ok = Config.validate(config)
    :ok = Supervisor.terminate_child(supervisor, {SmolBox.Runtime, @runtime})
    :ok = Supervisor.delete_child(supervisor, {SmolBox.Runtime, @runtime})

    {:ok, _} =
      Supervisor.start_child(
        supervisor,
        {SmolBox, Keyword.put(child_options, :workers, [config])}
      )

    ready(config.id)
    {:ok, %{state: :completed, result: ^result}} = Exports.fetch(@runtime, handle)
    copy_spec = create(@copy, Source.artifact(source), profile)
    command(@copy, copy_spec, "read", ["/bin/cat", marker], "original")
    command(@copy, copy_spec, "edit", ["/bin/sh", "-c", "printf copy > #{marker}"], "")
    command(@copy, copy_spec, "read-copy", ["/bin/cat", marker], "copy")
    lifecycle(@copy, :stop, :stopped)
    lifecycle(@copy, :delete, :deleted)
    lifecycle(@source, :start, :running)
    command(@source, source_spec, "unchanged", ["/bin/cat", marker], "original")
    lifecycle(@source, :stop, :stopped)
    lifecycle(@source, :delete, :deleted)
    {:ok, %{state: :completed, result: ^result}} = Exports.fetch(@runtime, handle)

    {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
      usage(store, config.id)

    archive(root, "deleted-source", idle(@source))
    archive(root, "deleted-copy", idle(@copy))

    save(root, "evidence", %{
      package_manifest_sha256: config.package_manifest_sha256,
      mode: mode,
      store: if(elem(store, 0) == Memory, do: "memory", else: "postgresql"),
      runtime_replacement: true,
      native_cleanup_resolved: true,
      export_history_after_delete: true,
      pinned_registry_reimport: true,
      source_and_copy_independent: true,
      final_reserved_slots: 0,
      manifest_sha256: result.manifest_sha256,
      content_sha256: result.content_sha256,
      size_bytes: result.size_bytes,
      crash_validation_deferred: true
    })
  end

  defp without_rust! do
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
  end

  defp store([]), do: {@store, [{Memory, name: elem(@store, 1)}], :ephemeral}

  defp store(["--postgres", settings]) do
    %{"partition" => partition, "key_file" => key_file} =
      settings |> File.read!() |> Jason.decode!()

    %{type: :regular, size: 32, mode: permissions} = File.lstat!(key_file)
    true = Bitwise.band(permissions, 0o077) == 0
    adapter = Code.ensure_loaded!(SmolBox.DurableHost.Store)
    {:ok, context} = adapter.new(SmolBox.DurableHost.Repo, partition, File.read!(key_file))

    {:ok, %{durable: true, managed_exports: 1, native_export_histories: 1}} =
      adapter.capabilities(context)

    {{adapter, context}, [], :durable}
  end

  defp runtime_options(store, mode, objects, fingerprint_key, workers) do
    [
      name: @runtime,
      namespace: "portexport",
      store: store,
      mode: mode,
      artifact_store: {Directory, objects},
      fingerprint_key: fingerprint_key,
      workers: workers,
      poll_ms: 50,
      lease_ms: 1000
    ]
  end

  defp usage({adapter, context}, worker), do: adapter.usage(context, worker)

  defp archived(root, label) do
    record = root |> Path.join("private-record-" <> label <> ".json") |> File.read!()
    {:ok, decoded} = record |> Jason.decode!() |> Base.decode64!() |> Codec.decode()
    decoded
  end

  defp create({scope, id} = key, artifact, profile) do
    {:ok, spec} =
      ManagedMachineSpec.new(scope: scope, id: id, artifact: artifact, profile: profile)

    {:ok, ^key} = Machines.create(@runtime, spec)
    %{state: :stopped} = idle(key)
    lifecycle(key, :start, :running)
    spec
  end

  defp command(key, machine, id, argv, expected) do
    {:ok, command} = Command.new(argv)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: machine.id <> "-" <> id,
        artifact: machine.artifact,
        profile: machine.profile,
        command: command
      )

    {:ok, handle} = Machines.submit(@runtime, key, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: ^expected}}} =
      SmolBox.await(@runtime, handle, @wait)

    %{state: :running} = idle(key)
  end

  defp ready(id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait
    {:ok, workers} = SmolBox.workers(@runtime)

    unless Enum.any?(workers, &(&1.id == id and &1.health_status == :ready)) do
      true = System.monotonic_time(:millisecond) < deadline
      Process.sleep(50)
      ready(id, deadline)
    end
  end

  defp idle(key) do
    {:ok, record} = Machines.await(@runtime, key, @wait)
    record
  end

  defp lifecycle(key, operation, expected, retries \\ 10) do
    record = idle(key)

    case apply(Machines, operation, [@runtime, key, record.version]) do
      {:ok, _} ->
        %{state: ^expected} = idle(key)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle(key, operation, expected, retries - 1)

      {:error, _} ->
        raise "ordinary export lifecycle admission failed"
    end
  end

  defp archive(root, stage, record) do
    {:ok, bytes} = Codec.encode(record)
    {:ok, ^record} = Codec.decode(bytes)
    save(root, "private-record-" <> stage, Base.encode64(bytes))
  end

  defp checked(root, operation, {:error, %SmolBox.Error{} = error} = result) do
    save(root, operation <> "-error", Map.take(error, [:category, :operation, :evidence]))
    result
  end

  defp checked(_root, _operation, result), do: result

  defp save(root, name, value) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(value), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end

SmolBox.ManagedExportProof.run(System.argv())
