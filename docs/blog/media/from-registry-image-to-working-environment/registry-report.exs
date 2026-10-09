defmodule RegistryReport do
  @moduledoc """
  A public Alpine image, a verified report, and explicit retained-machine cleanup.
  Run from the v0.4.1 durable_host example: mix run registry-report.exs prepare
  Then keep the same environment and keys: mix run registry-report.exs cleanup
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

  def run(phase) when phase in ["prepare", "cleanup"] do
    context = context()

    try do
      execute(phase, context)
    after
      Supervisor.stop(context.runtime)
    end
  end

  defp context do
    architecture = "x86_64"

    source = source(architecture)

    {:ok, endpoint} =
      Worker.new("registry-demo-worker", "http://localhost",
        unix_socket: System.fetch_env!("SMOLBOX_WORKER_SOCKET"),
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
        runtime_version: "1.22.0",
        architecture: architecture,
        platform: :linux,
        artifacts: [],
        sources: [source],
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
      handle: {spec.scope, spec.id}
    }
  end

  defp execute("prepare", context) do
    {:ok, handle} = Machines.create(context.runtime, context.spec)
    machine = wait_machine(context.runtime, handle, &(&1.state in [:created, :stopped, :running]))
    if machine.state != :running, do: lifecycle(context.runtime, handle, :start)
    wait_machine(context.runtime, handle, &(&1.state == :running))

    command(
      context,
      "report",
      [
        "/bin/sh",
        "-eu",
        "-c",
        ~S"""
        cat > /workspace/orders.csv <<'CSV'
        item,units
        notebook,3
        pencil,4
        folder,2
        CSV
        awk -F, 'NR > 1 { orders++; units += $2 }
          END { printf "orders=%d\nunits=%d\n", orders, units }' \
          /workspace/orders.csv > /workspace/report.txt
        """
      ],
      ""
    )

    # A different execution reads the file from the same retained machine.
    command(context, "verify", ["/bin/cat", "/workspace/report.txt"], "orders=3\nunits=9\n")
    IO.puts("Verified report:\norders=3\nunits=9")
    report(context, "prepare")
  end

  defp execute("cleanup", context) do
    # Inspect the existing identity; cleanup never creates a replacement.
    {:ok, original} = Machines.inspect(context.runtime, context.handle)
    true = original.spec == context.spec
    {:ok, _} = lifecycle(context.runtime, context.handle, :delete)
    deleted = wait_machine(context.runtime, context.handle, &(&1.state == :deleted))

    {:error, %{category: :not_found}} =
      Client.inspect_machine(context.client, deleted.machine_name)

    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(context.store, deleted.worker_id)
    IO.puts("Verified cleanup: machine absent; slot and disk reservations released.")
    report(context, "cleanup")
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
    {:ok, source} =
      Source.oci(
        id: "alpine-report",
        architecture: architecture,
        reference:
          "docker.io/library/alpine@sha256:3c81aa9a3d770b316568f4499e30461a5cd3fbd7180bd89e28e34894c7845832"
      )

    source
  end

  defp network do
    {:ok, network} =
      SmolBox.NetworkPolicy.new(hosts: ["docker.io", "docker.com", "cloudflarestorage.com"])

    network
  end
end

case System.argv() do
  [phase] when phase in ["prepare", "cleanup"] -> RegistryReport.run(phase)
  _ -> raise "usage: mix run registry-report.exs prepare|cleanup"
end
