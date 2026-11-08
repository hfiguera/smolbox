Code.require_file(Path.join(__DIR__, "owned_control.ex"))

defmodule SmolBox.Example.EmbeddedImages do
  @moduledoc """
  Explicit ordinary public OCI/image and registry-artifact qualification.
  An approved source catalog, package and real enrolled account are required.
  Failed workflows retain their original Runtime/store for exact-version control.
  This runner never injects process loss or retries uncertain mutations.
  """
  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.Embedded.{Config, RegistryPolicy}
  alias SmolBox.Example.{EmbeddedImagesControl, EmbeddedOwnedControl}
  alias SmolBox.Store.{Codec, Memory}

  alias SmolBox.{
    Command,
    ExecutionSpec,
    Files,
    GuestPaths,
    Image,
    ImageInventory,
    Machines,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile,
    Source,
    Workload
  }

  @scope "public-images-proof"
  @startup "set -eu; test \"$SMOLBOX_STARTUP_WITNESS\" = configured-v1; test \"$PWD\" = /tmp; test \"$(id -u)\" = 0; mkdir -p /workspace; printf 'configured-v1:/tmp:0\\n' >> /workspace/ordinary-images-startups"

  def configure(%Config{platform: :linux} = target, settings) do
    true =
      is_map(settings) and
        Map.keys(settings) -- ~w(source pull_source network cache_policy startup_workload) == []

    source = source(Map.fetch!(settings, "source"))
    true = source.architecture == target.architecture
    startup = Map.get(settings, "startup_workload", false)
    true = is_boolean(startup)

    {sources, network, registry} =
      case source.kind do
        :oci ->
          pull = source(Map.fetch!(settings, "pull_source"))
          true = pull.kind == :oci and pull.architecture == target.architecture
          true = not Map.has_key?(settings, "cache_policy")
          %{"hosts" => hosts, "cidrs" => cidrs} = policy = Map.fetch!(settings, "network")
          true = Enum.sort(Map.keys(policy)) == ~w(cidrs hosts)
          {:ok, network} = NetworkPolicy.new(hosts: hosts, cidrs: cidrs)
          {[source, pull] |> Enum.uniq(), network, nil}

        :registry ->
          true =
            not startup and not Map.has_key?(settings, "pull_source") and
              not Map.has_key?(settings, "network")

          %{
            "max_download_bytes" => download,
            "max_cache_bytes" => cache,
            "max_cache_files" => count
          } = policy = Map.fetch!(settings, "cache_policy")

          true =
            Enum.sort(Map.keys(policy)) == ~w(max_cache_bytes max_cache_files max_download_bytes)

          {:ok, registry} =
            RegistryPolicy.new(
              max_download_bytes: download,
              max_cache_bytes: cache,
              max_cache_files: count
            )

          {[source], :offline, registry}
      end

    {:ok, paths} =
      GuestPaths.new(
        workdir_roots: ["/tmp"],
        upload_roots: ["/workspace"],
        download_roots: ["/workspace"]
      )

    {:ok, profile} =
      Profile.new("public-images",
        cpus: 1,
        memory_mb: 512,
        guest_paths: paths,
        network: network,
        preparation_ms: 120_000,
        execution_ms: 60_000,
        max_file_bytes: 131_072
      )

    target = %{
      target
      | artifacts: [],
        sources: sources,
        profiles: [profile],
        registry_policy: registry,
        capacity: %{slots: 1, cpus: 1, memory_mb: 768, disk_gb: 2}
    }

    :ok = Config.validate(target)
    true = Config.sdk_identity(target)["feature_versions"]["remote_sources"] == 1
    true = Config.sdk_identity(target)["feature_versions"]["images"] == 1
    target
  end

  defp source(%{"kind" => "oci", "id" => id, "reference" => ref, "architecture" => arch} = value) do
    true = Enum.sort(Map.keys(value)) == ~w(architecture id kind reference)
    {:ok, source} = Source.oci(id: id, reference: ref, architecture: arch)
    source
  end

  defp source(
         %{
           "kind" => "registry",
           "id" => id,
           "reference" => ref,
           "architecture" => arch,
           "content_sha256" => hash
         } = value
       ) do
    true = Enum.sort(Map.keys(value)) == ~w(architecture content_sha256 id kind reference)

    {:ok, source} =
      Source.registry(id: id, reference: ref, architecture: arch, content_sha256: hash)

    source
  end

  def run(%Config{platform: :linux} = target, output, settings) do
    target = configure(target, settings)
    Process.flag(:trap_exit, true)
    Process.put({__MODULE__, :closed}, false)
    :ok = File.mkdir(output)
    :ok = File.chmod(output, 0o700)
    objects = Path.join(output, "objects")
    :ok = File.mkdir(objects)
    :ok = File.chmod(objects, 0o700)
    {:ok, objects} = Directory.new(objects, max_file_bytes: 131_072)
    store = {Memory, Module.concat(__MODULE__, Store)}
    key = :crypto.strong_rand_bytes(32)
    save(output, "private-fingerprint", Base.encode64(key))

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {Memory, name: elem(store, 1)},
          {SmolBox,
           name: __MODULE__,
           namespace: "portimages",
           store: store,
           mode: :ephemeral,
           artifact_store: {Directory, objects},
           fingerprint_key: key,
           workers: [target],
           poll_ms: 50,
           lease_ms: 1000}
        ],
        strategy: :one_for_one
      )

    c = %{
      root: output,
      supervisor: supervisor,
      target: target,
      store: store,
      objects: objects,
      source: hd(target.sources),
      profile: hd(target.profiles),
      startup: settings["startup_workload"] == true
    }

    try do
      ready(c)
      result = execute(c)
      clean(c)
      checkpoint(c, "before-close")

      evidence =
        Map.merge(result, %{
          "campaign" => "ordinary-public-native-images",
          "source_kind" => Atom.to_string(c.source.kind),
          "source" => Source.artifact(c.source),
          "store_mode" => "ephemeral",
          "package_manifest_sha256" => target.package_manifest_sha256,
          "identity" => target.package_identity,
          "owned_deleted" => true,
          "final_reserved_slots" => 0,
          "deliberate_process_interruption" => false,
          "crash_handling_qualified" => false
        })

      save(output, "evidence", evidence)
      :ok = close(c)
      {:ok, evidence}
    rescue
      error -> retain(c, %{exception: inspect(error.__struct__)})
    catch
      kind, _ -> retain(c, %{exception: inspect(kind)})
    end
  end

  defp execute(c) do
    key = create(c, "original")
    %{state: :stopped} = original = idle(key)
    preparation(c, original, false)

    {:ok, %ImageInventory{availability: :empty_or_unavailable}} =
      Machines.list_images(__MODULE__, key)

    lifecycle(key, :start, :running)
    startup(c, key, 1)
    command(c, key, "mkdir", "mkdir -p /workspace")
    data = :binary.copy(<<0, 255>>, 32_768) <> <<42>>
    :ok = Directory.seed(c.objects, @scope, "input", data)

    input = %{
      "source" => "input",
      "path" => "/workspace/ordinary-images-input",
      "size" => byte_size(data),
      "sha256" => Files.sha256(data),
      "mode" => "runtime_default"
    }

    spec =
      spec(c, "write", "cat /workspace/ordinary-images-input > /workspace/ordinary-images-data")

    {:ok, write} = Machines.submit(__MODULE__, key, %{spec | inputs: [input]})
    completed(write, 0)
    %{state: :running} = idle(key)
    images = images(c, key)
    before = idle(key)
    lifecycle(key, :stop, :stopped)
    :ok = Supervisor.terminate_child(c.supervisor, {SmolBox.Runtime, __MODULE__})
    {:ok, _} = Supervisor.restart_child(c.supervisor, {SmolBox.Runtime, __MODULE__})
    ready(c)
    %{state: :stopped, created_machine: creation} = idle(key)
    true = creation == before.created_machine
    lifecycle(key, :start, :running)
    startup(c, key, 2)

    output = %{
      "destination" => "retained",
      "path" => "/workspace/ordinary-images-data",
      "max_bytes" => 131_072
    }

    spec = %{spec(c, "read", "test -f /workspace/ordinary-images-data") | outputs: [output]}
    {:ok, read} = Machines.submit(__MODULE__, key, spec)
    completed(read, 0)
    {:ok, ^data} = Directory.read_output(c.objects, read, "retained", 131_072)
    %{state: :running} = idle(key)
    lifecycle(key, :stop, :stopped)
    lifecycle(key, :delete, :deleted)
    warm = warm(c)

    %{
      "image_operations" => images,
      "cold_warm_registry" => warm,
      "configured_startup" => c.startup,
      "startup_counts" => if(c.startup, do: [1, 2], else: []),
      "retained_binary_bytes" => byte_size(data),
      "retained_binary_sha256" => Files.sha256(data),
      "stopped_runtime_replacement" => true,
      "immutable_creation_retained" => true
    }
  end

  defp create(c, id) do
    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: @scope,
        id: id,
        profile: c.profile,
        artifact: Source.artifact(c.source),
        workload: workload(c)
      )

    {:ok, key} = Machines.create(__MODULE__, spec)
    checkpoint(c, "accepted-" <> id)
    key
  end

  defp workload(%{startup: false}), do: nil

  defp workload(%{startup: true}) do
    {:ok, workload} =
      Workload.new(
        entrypoint: ["/bin/sh", "-c"],
        cmd: [@startup],
        env: [{"SMOLBOX_STARTUP_WITNESS", "configured-v1"}],
        workdir: "/tmp"
      )

    workload
  end

  defp startup(%{startup: false}, _key, _count), do: :ok

  defp startup(c, key, count) do
    command(
      c,
      key,
      "startup-#{count}",
      "i=0; while [ \"$i\" -lt 200 ]; do if [ -f /workspace/ordinary-images-startups ] && [ \"$(wc -l < /workspace/ordinary-images-startups)\" -eq #{count} ]; then test \"$(tail -1 /workspace/ordinary-images-startups)\" = configured-v1:/tmp:0; exit; fi; i=$((i+1)); sleep 0.05; done; exit 1"
    )
  end

  defp preparation(%{source: %{kind: :oci}}, %{preparation: nil}, _cached), do: :ok

  defp preparation(c, record, cached) do
    %SmolBox.ArtifactPreparation{already_cached: ^cached} = record.preparation
    true = SmolBox.ArtifactPreparation.matches?(record.preparation, Source.artifact(c.source))
  end

  defp warm(%{source: %{kind: :oci}}), do: false

  defp warm(c) do
    key = create(c, "warm")
    %{state: :stopped} = record = idle(key)
    preparation(c, record, true)
    lifecycle(key, :delete, :deleted)
    true
  end

  defp images(%{source: %{kind: :registry}} = c, key) do
    {:ok, %ImageInventory{images: images}} = Machines.list_images(__MODULE__, key)
    true = Enum.all?(images, &(&1.digest_kind == :packed))

    {:error, %{category: :unsupported_capability, evidence: :not_dispatched}} =
      Machines.pull_image(__MODULE__, key, "packed-pull", c.source)

    %{"inventory_observed" => true, "imported_pull_rejected" => true}
  end

  defp images(c, key) do
    {:ok, %ImageInventory{availability: :observed, images: entries}} =
      Machines.list_images(__MODULE__, key)

    true = Enum.any?(entries, &Image.matches?(&1, c.source))
    source = Enum.find(c.target.sources, &(&1.id != c.source.id)) || c.source
    {:ok, pull} = Machines.pull_image(__MODULE__, key, "pull", source)
    {:ok, ^pull} = Machines.pull_image(__MODULE__, key, "pull", source)

    {:ok, %{state: :completed, evidence: :image_pulled, result: image}} =
      SmolBox.await(__MODULE__, pull, 180_000)

    true = Image.matches?(image, source)
    %{state: :running} = idle(key)
    {:ok, %ImageInventory{images: entries}} = Machines.list_images(__MODULE__, key)
    true = Enum.any?(entries, &Image.matches?(&1, source))

    %{
      "inventory_observed" => true,
      "approved_pull_observed" => true,
      "duplicate_pull_reused" => true,
      "creation_source_unchanged" => idle(key).spec.artifact == Source.artifact(c.source)
    }
  end

  defp spec(c, id, script) do
    {:ok, command} = Command.new(["/bin/sh", "-c", script], workdir: "/tmp")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: @scope,
        id: id,
        artifact: Source.artifact(c.source),
        profile: c.profile,
        command: command
      )

    spec
  end

  defp command(c, key, id, script) do
    {:ok, handle} = Machines.submit(__MODULE__, key, spec(c, id, script))
    completed(handle, 0)
    %{state: :running} = idle(key)
    :ok
  end

  defp completed(handle, code) do
    {:ok, %{state: :completed, result: %{exit_code: ^code}}} =
      SmolBox.await(__MODULE__, handle, 180_000)
  end

  defp idle(key) do
    {:ok, record} = Machines.await(__MODULE__, key, 180_000)
    record
  end

  defp lifecycle(key, operation, expected, retries \\ 10) do
    record = idle(key)

    case apply(Machines, operation, [__MODULE__, key, record.version]) do
      {:ok, _} ->
        %{state: ^expected} = idle(key)

      {:error, %{category: :stale_version, evidence: :not_dispatched}} when retries > 0 ->
        lifecycle(key, operation, expected, retries - 1)

      _ ->
        raise "ordinary image lifecycle admission failed"
    end
  end

  defp ready(c) do
    wait(
      fn ->
        {:ok, workers} = SmolBox.workers(__MODULE__)
        Enum.any?(workers, &(&1.id == c.target.id and &1.health_status == :ready))
      end,
      System.monotonic_time(:millisecond) + 180_000
    )
  end

  defp wait(check, deadline) do
    unless check.() do
      true = System.monotonic_time(:millisecond) < deadline
      Process.sleep(50)
      wait(check, deadline)
    end
  end

  defp records(c, cursor \\ nil, count \\ 0) do
    {adapter, store} = c.store
    {:ok, page, next} = adapter.backend_assignments(store, c.target.id, cursor, 100)
    true = count + length(page) <= 1024
    if next, do: page ++ records(c, next, count + length(page)), else: page
  end

  defp checkpoint(c, label) do
    encoded =
      Enum.map(records(c), fn record ->
        {:ok, bytes} = Codec.encode(record)
        Base.encode64(bytes)
      end)

    save(c.root, "private-records-" <> label, encoded)
  end

  defp clean(c) do
    # The worker projection omits accepted, unassigned machines. Check every
    # identity this workflow may create before trusting zero worker usage.
    for id <- ~w(original warm) do
      case Machines.inspect(__MODULE__, {@scope, id}) do
        {:ok, record} -> true = collected?(record)
        {:error, %{category: :not_found}} -> :ok
        _ -> raise "workflow machine is not positively collected"
      end
    end

    {adapter, store} = c.store
    {:ok, usage} = adapter.usage(store, c.target.id)
    true = usage.slots == 0 and usage.disk_gb == 0 and usage.cpus == 0 and usage.memory_mb == 0
    true = Enum.all?(records(c), &collected?/1)
    :ok
  end

  @doc false
  def collected?(
        %SmolBox.ManagedMachine{scope: @scope, state: :deleted, reservation: nil} = record
      ),
      do: SmolBox.ManagedMachine.validate(record) == :ok

  def collected?(
        %SmolBox.Execution{
          scope: @scope,
          state: :completed,
          cleanup: :complete,
          reservation: nil
        } = record
      ),
      do: SmolBox.Execution.validate(record) == :ok

  def collected?(_), do: false

  @doc false
  def stop_owned(c, id, version) when id in ~w(original warm),
    do: EmbeddedOwnedControl.stop(__MODULE__, c.target.id, {@scope, id}, version)

  @doc false
  def close(c) do
    :ok = SmolBox.drain_worker(__MODULE__, c.target.id)
    :ok = clean(c)
    :ok = Supervisor.stop(c.supervisor)
    Process.put({__MODULE__, :closed}, true)
    :ok
  end

  defp retain(c, diagnostic) do
    try do
      save(c.root, "failure", diagnostic)
      checkpoint(c, "failure")
    rescue
      _ -> :diagnostic_unavailable
    catch
      _, _ -> :diagnostic_unavailable
    end

    unless Process.get({__MODULE__, :closed}), do: EmbeddedImagesControl.wait(c, &close/1)
    {:error, :qualification_failed}
  end

  @doc false
  def save(root, name, value) do
    path = Path.join(root, name <> ".json")
    File.write!(path <> ".new", Jason.encode!(value), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end
