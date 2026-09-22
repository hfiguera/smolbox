defmodule SmolBox.DurableHost.PersistentHTTPDemo do
  @moduledoc """
  A retained HTTP service with fixed TCP forwarding. Run prepare and resume in
  separate BEAM processes with the same PostgreSQL partition and keys. The caller
  must be able to reach the worker's loopback listener (or configure a trusted
  forwarding path with SMOLBOX_HTTP_URL).
  """
  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    LaunchResult,
    Machines,
    ManagedMachineSpec,
    PortMapping,
    Runtime
  }

  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Example.Setup
  import SmolBox.DurableHost.PersistentSteps

  @readiness """
  import time, urllib.request
  for attempt in range(40):
      try:
          assert urllib.request.urlopen('http://127.0.0.1:8000/retained.txt', timeout=.1).read() == b'retained\\n'
          print('ready')
          break
      except OSError:
          time.sleep(.05)
  else:
      raise RuntimeError('HTTP service did not become ready')
  """

  def run(phase) when phase in ["prepare", "resume"] do
    settings = Setup.environment()

    {:ok, mapping} =
      PortMapping.new(
        host: System.fetch_env!("SMOLBOX_HTTP_PORT") |> String.to_integer(),
        guest: 8000
      )

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _objects} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)
    {:ok, runtime} = Runtime.start_link(options)
    handle = {"persistent-http", settings["id"]}
    url = System.get_env("SMOLBOX_HTTP_URL", "http://127.0.0.1:#{mapping.host}/retained.txt")

    context = %{
      runtime: runtime,
      handle: handle,
      base: base,
      mapping: mapping,
      store: store,
      url: url,
      client: hd(options[:workers]).client
    }

    try do
      execute(phase, context)
    after
      Supervisor.stop(runtime)
    end
  end

  defp execute("prepare", c) do
    {scope, id} = c.handle

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: scope,
        id: id,
        artifact: c.base.artifact,
        profile: c.base.profile,
        ports: [c.mapping]
      )

    {:ok, _} = Machines.create(c.runtime, spec)
    wait_machine(c.runtime, c.handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))

    command(
      c.runtime,
      c.handle,
      c.base,
      "write",
      "from pathlib import Path; Path('/workspace/retained.txt').write_text('retained\\n'); print('written')",
      "written\n"
    )

    launch = launch(c, "serve")
    command(c.runtime, c.handle, c.base, "ready", @readiness, "ready\n")
    probe(c.url)
    {:ok, machine} = Machines.inspect(c.runtime, c.handle)
    true = machine.reserved_ports == [c.mapping.host]

    report("prepare", machine, %{
      http_verified: true,
      reservation_retained: true,
      launch_pid: launch.result.pid,
      launch_id: launch.id
    })
  end

  defp execute("resume", c) do
    {:ok, original} = Machines.inspect(c.runtime, c.handle)
    true = original.spec.ports == [c.mapping] and original.reserved_ports == [c.mapping.host]
    {scope, id} = c.handle
    {:ok, launch} = SmolBox.fetch(c.runtime, scope, id <> "-serve")
    :launched = launch.state
    %LaunchResult{} = launch.result
    {:ok, duplicate} = Machines.submit(c.runtime, c.handle, launch.spec)
    true = duplicate == {launch.scope, launch.id}
    probe(c.url)
    {:ok, _} = lifecycle(c.runtime, c.handle, :stop)
    stopped = wait_machine(c.runtime, c.handle, &(&1.state == :stopped))
    true = stopped.reserved_ports == original.reserved_ports
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    restarted = wait_machine(c.runtime, c.handle, &(&1.state == :running))
    true = restarted.created_machine == original.created_machine
    restarted_launch = launch(c, "serve-after-start")
    command(c.runtime, c.handle, c.base, "ready-after-start", @readiness, "ready\n")
    probe(c.url)
    {:ok, _} = lifecycle(c.runtime, c.handle, :delete)
    deleted = wait_machine(c.runtime, c.handle, &(&1.state == :deleted))

    true =
      deleted.absence_at_ms != nil and deleted.reserved_ports == [] and deleted.reservation == nil

    {:error, %{category: :not_found}} = Client.inspect_machine(c.client, deleted.machine_name)

    {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
      Store.usage(c.store, deleted.worker_id)

    %{rows: [[0]]} =
      Database.query(c.store, "SELECT count(*) FROM smolbox_port_owners WHERE partition=$1", [
        c.store.partition
      ])

    {:ok, handle} = Machines.create(c.runtime, original.spec)
    true = handle == c.handle
    {:ok, %{state: :deleted}} = Machines.inspect(c.runtime, handle)

    report("resume", deleted, %{
      http_verified: true,
      recovered_launch_pid: launch.result.pid,
      recovered_launch_id: launch.id,
      restarted_launch_id: restarted_launch.id,
      same_machine: true,
      absence_verified: true,
      ports_released: true,
      resources_released: true,
      deduplication_retained: true
    })
  end

  defp launch(c, suffix) do
    {scope, id} = c.handle

    {:ok, command} =
      Command.new(
        ["python", "-m", "http.server", "8000", "--bind", "0.0.0.0", "--directory", "/workspace"],
        background: true
      )

    {:ok, spec} =
      ExecutionSpec.new(
        scope: scope,
        id: id <> "-" <> suffix,
        artifact: c.base.artifact,
        profile: c.base.profile,
        command: command
      )

    {:ok, execution} = Machines.submit(c.runtime, c.handle, spec)

    {:ok, %{state: :launched, result: %LaunchResult{}} = launched} =
      SmolBox.await(c.runtime, execution, 90_000)

    wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))
    launched
  end

  defp probe(url) do
    # This URL is operator configuration, and the response is an exact, tiny
    # fixture. No redirects or retries conceal a wrong host or stale service.
    {:ok, %{status: 200, body: "retained\n"}} =
      Req.get(url, retry: false, redirect: false, decode_body: false, receive_timeout: 3000)
  end

  defp report(phase, machine, evidence),
    do:
      IO.puts(
        Jason.encode!(
          Map.merge(evidence, %{
            phase: phase,
            machine_name: machine.machine_name,
            state: machine.state,
            mappings: Enum.map(machine.spec.ports, &Map.from_struct/1)
          })
        )
      )
end
