defmodule SmolBox.DurableHost.VolumeDemo do
  @moduledoc """
  Run prepare/resume in separate BEAMs with the same durable environment.
  Prepare leaves a volume after deleting its original machine. Resume reads and
  modifies the data in a replacement, checks a read-only attachment, then removes
  the machines and volume. Requires the approved Python fixture and an explicit
  SMOLBOX_VOLUME_ROOT matching the worker's canonical local volume directory.
  """
  alias SmolBox.DurableHost.{PersistentSteps, Repo, Store}
  alias SmolBox.Example.Setup

  alias SmolBox.{
    Client,
    Machines,
    ManagedMachineSpec,
    Runtime,
    Volume,
    VolumeMount,
    VolumePolicy,
    Volumes
  }

  import SmolBox.DurableHost.PersistentSteps, only: [wait_machine: 3, lifecycle: 3, command: 6]

  def run(phase) when phase in ["prepare", "resume"] do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _} = Setup.build(settings, {Store, store}, :durable, SmolBox.VolumeDemo)
    {options, base} = PersistentSteps.small_profile(options, base)
    {:ok, policy} = VolumePolicy.new("local-demo", System.fetch_env!("SMOLBOX_VOLUME_ROOT"))
    [worker] = options[:workers]
    worker = %{worker | volume_policy: policy, capacity: %{worker.capacity | disk_gb: 10}}
    {:ok, runtime} = Runtime.start_link(Keyword.put(options, :workers, [worker]))

    context = %{
      runtime: runtime,
      base: base,
      worker: worker,
      store: store,
      scope: "volume-demo",
      id: settings["id"]
    }

    try do
      execute(phase, context)
    after
      Supervisor.stop(runtime)
    end
  end

  defp execute("prepare", c) do
    {:ok, volume} =
      Volumes.create(c.runtime,
        scope: c.scope,
        id: c.id,
        worker_id: c.worker.client.worker.id,
        size_gb: 2
      )

    {:ok, %{state: :ready}} = Volumes.inspect(c.runtime, volume)
    machine = create(c, "original", false)

    command(
      c.runtime,
      machine,
      c.base,
      "volume-write",
      "from pathlib import Path; Path('/mnt/volumes/data/kept.txt').write_text('original'); print('saved')",
      "saved\n"
    )

    {:ok, held} = Volumes.inspect(c.runtime, volume)
    {:error, %{category: :admission_exhausted}} = Volumes.delete(c.runtime, volume, held.version)
    delete(c, machine)
    {:ok, %{state: :ready, attached_to: nil} = v} = Volumes.inspect(c.runtime, volume)
    {:ok, %{disk_gb: 2}} = Store.usage(c.store, c.worker.client.worker.id)

    IO.puts(
      Jason.encode!(%{
        phase: "prepare",
        volume_path: Volume.path(v),
        original_deleted: true,
        reserved_disk_gb: 2
      })
    )
  end

  defp execute("resume", c) do
    volume = {c.scope, c.id}
    {:ok, %{state: :ready, attached_to: nil}} = Volumes.inspect(c.runtime, volume)
    machine = create(c, "replacement", false)

    command(
      c.runtime,
      machine,
      c.base,
      "volume-modify",
      "from pathlib import Path; p=Path('/mnt/volumes/data/kept.txt'); assert p.read_text() == 'original'; p.write_text('replacement'); print(p.read_text())",
      "replacement\n"
    )

    delete(c, machine)
    readonly = create(c, "readonly", true)

    command(
      c.runtime,
      readonly,
      c.base,
      "volume-readonly",
      """
      from pathlib import Path
      p=Path('/mnt/volumes/data/kept.txt')
      assert p.read_text() == 'replacement'
      try:
          p.write_text('must fail')
      except OSError:
          print('read only enforced')
      else:
          raise AssertionError('write unexpectedly succeeded')
      """,
      "read only enforced\n"
    )

    delete(c, readonly)
    {:ok, v} = Volumes.inspect(c.runtime, volume)
    {:ok, %{state: :deleted}} = Volumes.delete(c.runtime, volume, v.version)
    {:ok, %{disk_gb: 0, slots: 0}} = Store.usage(c.store, c.worker.client.worker.id)

    IO.puts(
      Jason.encode!(%{
        phase: "resume",
        files_preserved: true,
        files_modified: true,
        readonly_enforced: true,
        restarted_controller: true,
        reserved_disk_gb: 0,
        deleted_volume_path: Volume.path(v)
      })
    )
  end

  defp create(c, suffix, readonly) do
    {:ok, mount} = VolumeMount.new(c.id, "/mnt/volumes/data", readonly: readonly)

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: c.scope,
        id: c.id <> "-" <> suffix,
        artifact: c.base.artifact,
        profile: c.base.profile,
        volumes: [mount]
      )

    {:ok, machine} = Machines.create(c.runtime, spec)
    wait_machine(c.runtime, machine, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, machine, :start)
    wait_machine(c.runtime, machine, &(&1.state == :running))
    machine
  end

  defp delete(c, machine) do
    wait_machine(c.runtime, machine, &is_nil(&1.active_execution))
    {:ok, _} = lifecycle(c.runtime, machine, :stop)
    wait_machine(c.runtime, machine, &(&1.state == :stopped))
    {:ok, _} = lifecycle(c.runtime, machine, :delete)
    deleted = wait_machine(c.runtime, machine, &(&1.state == :deleted))

    {:error, %{category: :not_found}} =
      Client.inspect_machine(c.worker.client, deleted.machine_name)

    {:ok, %{disk_gb: 2, slots: 0}} = Store.usage(c.store, c.worker.client.worker.id)
  end
end
