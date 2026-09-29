defmodule SmolBox.DurableHost.RegistryDemo do
  @moduledoc """
  Approved registry creation and optional OCI pulls across two BEAM invocations.
  Run `prepare`, optionally `images`, then `resume` with identical environment
  and durable keys. See the example README for required operator approvals.
  """
  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    Machines,
    ManagedMachineSpec,
    Profile,
    Runtime,
    Source,
    Worker
  }

  alias SmolBox.ArtifactStore.Directory
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.Runtime.WorkerConfig
  import SmolBox.DurableHost.PersistentSteps, only: [lifecycle: 3, wait_machine: 3]

  def run(phase) when phase in ["prepare", "images", "resume"] do
    context = context()

    try do
      execute(phase, context)
    after
      Supervisor.stop(context.runtime)
    end
  end

  defp context do
    architecture = System.fetch_env!("SMOLBOX_ARCHITECTURE")

    source = source(architecture)

    pull = pull_source(architecture)

    {:ok, endpoint} =
      Worker.new("registry-demo-worker", System.fetch_env!("SMOLBOX_WORKER_URL"),
        allow_insecure_loopback: System.get_env("SMOLBOX_ALLOW_LOOPBACK") == "true",
        operation_timeout_ms: 120_000
      )

    {:ok, client} = Client.new(endpoint)

    {:ok, profile} =
      Profile.new("registry-demo-v1",
        storage_gb: 20,
        overlay_gb: 10,
        host_overhead_mb: 768,
        preparation_ms: 120_000,
        execution_ms: 120_000,
        network: network()
      )

    {:ok, worker} =
      WorkerConfig.new(
        client: client,
        runtime_version: System.get_env("SMOLBOX_RUNTIME_VERSION", "1.20.2"),
        architecture: architecture,
        platform: platform(),
        artifacts: [],
        sources: Enum.reject([source, pull], &is_nil/1),
        profiles: [profile],
        capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 30},
        allocation_floor: %{storage_gb: 20, overlay_gb: 10, host_overhead_mb: 768}
      )

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {:ok, objects} = Directory.new(System.fetch_env!("SMOLBOX_ARTIFACT_DIR"))

    {:ok, runtime} =
      Runtime.start_link(
        name: __MODULE__,
        namespace: "regdemo",
        store: {Store, store},
        mode: :durable,
        artifact_store: {Directory, objects},
        fingerprint_key: Setup.key(System.fetch_env!("SMOLBOX_FINGERPRINT_KEY_FILE")),
        workers: [worker],
        poll_ms: 50,
        lease_ms: 1000
      )

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "registry-demo",
        id: System.fetch_env!("SMOLBOX_EXECUTION_ID"),
        artifact: Source.artifact(source),
        profile: profile
      )

    %{
      runtime: runtime,
      client: client,
      store: store,
      spec: spec,
      handle: {spec.scope, spec.id},
      pull: pull
    }
  end

  defp execute("prepare", context) do
    {:ok, handle} = Machines.create(context.runtime, context.spec)
    true = handle == context.handle
    machine = wait_machine(context.runtime, handle, &(&1.state in [:created, :running]))
    if machine.state == :created, do: lifecycle(context.runtime, handle, :start)
    wait_machine(context.runtime, handle, &(&1.state == :running))

    command(
      context,
      "write",
      ["/bin/sh", "-c", "printf retained > /workspace/registry-demo.txt"],
      ""
    )

    command(
      context,
      "read-before-restart",
      ["/bin/cat", "/workspace/registry-demo.txt"],
      "retained"
    )

    report(context, "prepare")
  end

  defp execute("images", %{pull: %Source{}} = context) do
    {:ok, before} = Machines.list_images(context.runtime, context.handle)

    {:ok, handle} =
      Machines.pull_image(
        context.runtime,
        context.handle,
        operation_id(context, "pull"),
        context.pull
      )

    {:ok, %{state: :completed, evidence: :image_pulled, result: image}} =
      SmolBox.await(context.runtime, handle, 120_000)

    wait_machine(context.runtime, context.handle, &is_nil(&1.active_execution))
    {:ok, after_pull} = Machines.list_images(context.runtime, context.handle)

    IO.puts(
      Jason.encode!(%{
        before_count: length(before.images),
        after_count: length(after_pull.images),
        image: Map.from_struct(image)
      })
    )
  end

  defp execute("resume", context) do
    {:ok, original} = Machines.inspect(context.runtime, context.handle)
    true = original.spec == context.spec

    command(
      context,
      "read-after-restart",
      ["/bin/cat", "/workspace/registry-demo.txt"],
      "retained"
    )

    {:ok, _} = lifecycle(context.runtime, context.handle, :stop)
    stopped = wait_machine(context.runtime, context.handle, &(&1.state == :stopped))
    true = stopped.reservation != nil
    {:ok, _} = lifecycle(context.runtime, context.handle, :start)
    restarted = wait_machine(context.runtime, context.handle, &(&1.state == :running))
    true = restarted.created_machine == original.created_machine
    command(context, "read-after-start", ["/bin/cat", "/workspace/registry-demo.txt"], "retained")
    {:ok, _} = lifecycle(context.runtime, context.handle, :delete)
    deleted = wait_machine(context.runtime, context.handle, &(&1.state == :deleted))

    {:error, %{category: :not_found}} =
      Client.inspect_machine(context.client, deleted.machine_name)

    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(context.store, deleted.worker_id)
    report(context, "resume")
  end

  defp command(context, suffix, argv, expected) do
    {:ok, command} = Command.new(argv)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: context.spec.scope,
        id: operation_id(context, suffix),
        artifact: context.spec.artifact,
        profile: context.spec.profile,
        command: command
      )

    {:ok, handle} = Machines.submit(context.runtime, context.handle, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: ^expected}}} =
      SmolBox.await(context.runtime, handle, 120_000)

    wait_machine(context.runtime, context.handle, &is_nil(&1.active_execution))
  end

  defp report(context, phase) do
    {:ok, machine} = Machines.inspect(context.runtime, context.handle)

    IO.puts(
      Jason.encode!(%{
        phase: phase,
        state: machine.state,
        machine_name: machine.machine_name,
        source: machine.spec.artifact,
        preparation: if(machine.preparation, do: Map.from_struct(machine.preparation)),
        reservation_retained: machine.reservation != nil,
        absence_verified: machine.absence_at_ms != nil
      })
    )
  end

  defp operation_id(context, suffix), do: context.spec.id <> ":" <> suffix

  defp source(architecture) do
    options = [
      id: "registry-environment",
      architecture: architecture,
      reference: System.fetch_env!("SMOLBOX_REGISTRY_REFERENCE")
    ]

    {:ok, source} =
      case System.get_env("SMOLBOX_SOURCE_KIND", "registry") do
        "registry" ->
          Source.registry(
            options ++ [content_sha256: System.fetch_env!("SMOLBOX_REGISTRY_CONTENT_SHA256")]
          )

        "oci" ->
          Source.oci(options)
      end

    source
  end

  defp network do
    case System.get_env("SMOLBOX_REGISTRY_NETWORK_HOSTS") do
      nil ->
        :offline

      hosts ->
        {:ok, network} = SmolBox.NetworkPolicy.new(hosts: String.split(hosts, ","))
        network
    end
  end

  defp pull_source(architecture) do
    case System.get_env("SMOLBOX_PULL_REFERENCE") do
      nil ->
        nil

      reference ->
        {:ok, source} =
          Source.oci(id: "pull-environment", reference: reference, architecture: architecture)

        source
    end
  end

  defp platform do
    case System.fetch_env!("SMOLBOX_PLATFORM") do
      "linux" -> :linux
      "macos" -> :macos
    end
  end
end
