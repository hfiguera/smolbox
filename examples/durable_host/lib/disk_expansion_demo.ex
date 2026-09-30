defmodule SmolBox.DurableHost.DiskExpansionDemo do
  @moduledoc """
  Run `prepare` and `resume` in separate BEAM processes with the same environment.
  Keeps creation identity and guest files while growing disks from 2/2 to 4/3 GiB.
  The prepare phase leaves the stopped machine retained; resume verifies guest
  filesystem growth and deletes it. Requires the approved Python fixture.
  """
  alias SmolBox.DurableHost.{PersistentSteps, Repo, Store}
  alias SmolBox.Example.Setup
  alias SmolBox.{Machines, ManagedMachineSpec, Runtime}
  import SmolBox.DurableHost.PersistentSteps, only: [wait_machine: 3, lifecycle: 3, command: 6]

  def run(phase) when phase in ["prepare", "resume"] do
    settings = Setup.environment()

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _} =
      Setup.build(settings, {Store, store}, :durable, SmolBox.DiskExpansionDemo)

    {options, base} = PersistentSteps.small_profile(options, base)
    workers = Enum.map(options[:workers], &%{&1 | capacity: %{&1.capacity | disk_gb: 8}})
    {:ok, runtime} = Runtime.start_link(Keyword.put(options, :workers, workers))
    handle = {"disk-growth-demo", settings["id"]}

    try do
      execute(phase, runtime, handle, base, store)
    after
      Supervisor.stop(runtime)
    end
  end

  defp execute("prepare", runtime, {scope, id} = handle, base, _store) do
    {:ok, spec} =
      ManagedMachineSpec.new(scope: scope, id: id, artifact: base.artifact, profile: base.profile)

    {:ok, ^handle} = Machines.create(runtime, spec)
    wait_machine(runtime, handle, &(&1.state == :created))
    {:ok, _} = lifecycle(runtime, handle, :start)
    wait_machine(runtime, handle, &(&1.state == :running))

    command(
      runtime,
      handle,
      base,
      "write",
      """
      import os, json
      from pathlib import Path
      sizes = {p: os.statvfs(p).f_blocks * os.statvfs(p).f_frsize for p in ['/workspace', '/']}
      Path('/workspace/growth.json').write_text(json.dumps(sizes))
      Path('/workspace/kept.txt').write_text('retained')
      print('saved')
      """,
      "saved\n"
    )

    {:ok, _} = lifecycle(runtime, handle, :stop)
    stopped = wait_machine(runtime, handle, &(&1.state == :stopped))

    {:ok, _} =
      Machines.expand_disks(runtime, handle, "grow-once", stopped.version,
        storage_gb: 4,
        overlay_gb: 3
      )

    grown = wait_machine(runtime, handle, &(&1.active_expansion == nil))
    :completed = grown.disk_expansions["grow-once"].state
    7 = grown.reservation.disk_gb
    true = grown.created_machine == stopped.created_machine

    IO.puts(
      Jason.encode!(%{
        phase: "prepare",
        machine: grown.machine_name,
        disks: grown.disk_sizes,
        reserved_disk_gb: 7,
        immutable_creation: true
      })
    )
  end

  defp execute("resume", runtime, handle, base, store) do
    {:ok, before} = Machines.inspect(runtime, handle)
    :completed = before.disk_expansions["grow-once"].state
    {:ok, _} = lifecycle(runtime, handle, :start)
    wait_machine(runtime, handle, &(&1.state == :running))

    command(
      runtime,
      handle,
      base,
      "verify",
      """
      import os, json, time
      from pathlib import Path
      before = json.loads(Path('/workspace/growth.json').read_text())
      assert Path('/workspace/kept.txt').read_text() == 'retained'
      for attempt in range(100):
          after = {p: os.statvfs(p).f_blocks * os.statvfs(p).f_frsize for p in before}
          if all(after[p] > before[p] for p in before):
              break
          time.sleep(0.02)
      assert all(after[p] > before[p] for p in before), (before, after)
      print('files retained; both filesystems grew')
      """,
      "files retained; both filesystems grew\n"
    )

    {:ok, _} = lifecycle(runtime, handle, :stop)
    wait_machine(runtime, handle, &(&1.state == :stopped))

    PersistentSteps.delete_machine(%{
      runtime: runtime,
      handle: handle,
      store: store,
      client: client(runtime)
    })

    IO.puts(
      Jason.encode!(%{
        phase: "resume",
        recovered: true,
        files_preserved: true,
        guest_filesystems_grew: true
      })
    )
  end

  defp client(runtime) do
    {:ok, config} = GenServer.call(Runtime.coordinator(runtime), :config)
    hd(config.workers).client
  end
end
