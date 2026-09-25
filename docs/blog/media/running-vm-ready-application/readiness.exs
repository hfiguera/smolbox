# Run from examples/durable_host after its documented setup and migrations.
# The worker must be dedicated, with an approved Python image and a free host port.
defmodule ReadinessProbe do
  def check(url, instance) do
    case Req.get(url,
           retry: false,
           redirect: false,
           finch: [
             receive_timeout: 500,
             pool_timeout: 500,
             conn_opts: [transport_opts: [timeout: 500]]
           ],
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"service" => "readiness-demo", "instance" => ^instance}} -> :ready
          _ -> :unexpected_response
        end

      {:ok, %{status: status}} ->
        {:http_status, status}

      {:error, _reason} ->
        :unreachable
    end
  end

  def await(url, instance, attempts \\ 40) do
    Enum.reduce_while(1..attempts, [], fn _, observations ->
      observation = check(url, instance)
      seen = observations ++ [observation]

      if observation == :ready do
        {:halt, {:ok, seen}}
      else
        Process.sleep(250)
        {:cont, seen}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, observations}
      observations -> {:error, observations}
    end
  end
end

defmodule ReadinessWalkthrough do
  alias SmolBox.{Command, ExecutionSpec, Machines, ManagedMachineSpec, Runtime, Workload}
  alias SmolBox.DurableHost.{Repo, Store}
  alias SmolBox.Example.Setup
  import SmolBox.DurableHost.PersistentSteps

  @program ~S"""
  import http.server, json, os, pathlib, time
  root = pathlib.Path('/workspace')
  root.mkdir(exist_ok=True)
  with (root / 'service-starts').open('a') as f:
      f.write('started\n')
  ready_at = time.monotonic() + 6
  class Handler(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
          if self.path != '/ready':
              self.send_error(404)
              return
          ready = time.monotonic() >= ready_at
          body = json.dumps({'service': 'readiness-demo', 'instance': os.environ['INSTANCE']}).encode()
          self.send_response(200 if ready else 503)
          self.send_header('Content-Type', 'application/json')
          self.send_header('Content-Length', str(len(body)))
          self.end_headers()
          self.wfile.write(body)
      def log_message(self, fmt, *args):
          with (root / 'service.log').open('a') as f:
              f.write((fmt % args) + '\n')
  http.server.HTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
  """

  def run(scenario) when scenario in ["healthy", "broken", "background", "delete"] do
    settings = Setup.environment()
    port = String.to_integer(System.get_env("READINESS_PORT", "18080"))
    true = port in 1024..65_535

    {:ok, store} =
      Store.new(
        Repo,
        System.fetch_env!("SMOLBOX_STORE_PARTITION"),
        Setup.key(System.fetch_env!("SMOLBOX_ENCRYPTION_KEY_FILE"))
      )

    {options, base, _} = Setup.build(settings, {Store, store}, :durable, __MODULE__)
    {options, base} = small_profile(options, base)
    {:ok, runtime} = Runtime.start_link(options)

    c = %{
      runtime: runtime,
      base: base,
      store: store,
      client: hd(options[:workers]).client,
      handle: {"readiness-blog", settings["id"]},
      port: port,
      url: System.get_env("READINESS_URL", "http://127.0.0.1:#{port}/ready")
    }

    try do
      if scenario == "delete" do
        delete_machine(c)
      else
        demonstrate(c, scenario)
        delete_machine(c)
      end
    after
      Supervisor.stop(runtime)
    end
  end

  defp demonstrate(c, scenario) do
    workload =
      case scenario do
        "healthy" ->
          {:ok, value} =
            Workload.new(
              entrypoint: ["python"],
              cmd: ["-c", @program],
              env: [{"INSTANCE", elem(c.handle, 1)}],
              workdir: "/",
              restart: :never
            )

          value

        "broken" ->
          {:ok, value} = Workload.new(entrypoint: ["/missing-readiness-app"], cmd: [])
          value

        "background" ->
          nil
      end

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1),
        artifact: c.base.artifact,
        profile: c.base.profile,
        workload: workload,
        ports: [%SmolBox.PortMapping{host: c.port, guest: 8000}]
      )

    {:ok, handle} = Machines.create(c.runtime, spec)
    true = handle == c.handle
    wait_machine(c.runtime, handle, &(&1.state == :created))
    {:ok, _} = lifecycle(c.runtime, handle, :start)
    wait_machine(c.runtime, handle, &(&1.state == :running))
    report(%{scenario: scenario, vm: "running"})
    exercise(c, scenario)
  end

  defp exercise(c, "broken") do
    {:error, observations} = ReadinessProbe.await(c.url, elem(c.handle, 1), 8)
    report(%{probe: inspect(observations), application: "not ready"})
    {:ok, %{source: :console, lines: lines}} = Machines.logs(c.runtime, c.handle, tail: 20)
    report(%{console_lines: length(lines), console_is_application_stdout: false})
    result = exec(c, "diagnose", ["/bin/sh", "-c", "exec /missing-readiness-app"])
    true = result.exit_code != 0
    report(%{diagnostic_exit: result.exit_code, diagnostic_stderr: result.stderr})
    {:ok, %{state: :running}} = Machines.inspect(c.runtime, c.handle)
  end

  defp exercise(c, scenario) do
    if scenario == "background", do: launch(c, "launch")
    ready(c, "first start")
    :unexpected_response = ReadinessProbe.check(c.url, "wrong-instance")
    report(%{wrong_instance_rejected: true})
    {:ok, _} = lifecycle(c.runtime, c.handle, :stop)
    wait_machine(c.runtime, c.handle, &(&1.state == :stopped))
    {:ok, _} = lifecycle(c.runtime, c.handle, :start)
    wait_machine(c.runtime, c.handle, &(&1.state == :running))

    if scenario == "background" do
      {:error, _} = ReadinessProbe.await(c.url, elem(c.handle, 1), 8)
      report(%{after_vm_restart: "background service absent"})
      launch(c, "explicit-relaunch")
    end

    ready(c, "after stop/start")
    result = exec(c, "read-starts", ["cat", "/workspace/service-starts"])
    "started\nstarted\n" = result.stdout
    report(%{startup_count: 2, retained_file: true})
  end

  defp launch(c, suffix) do
    result =
      exec(c, suffix, ["python", "-c", @program],
        background: true,
        env: [{"INSTANCE", elem(c.handle, 1)}]
      )

    %SmolBox.LaunchResult{pid: pid} = result
    report(%{launch_pid: pid, readiness: "not yet checked"})
  end

  defp ready(c, phase) do
    {:ok, observations} = ReadinessProbe.await(c.url, elem(c.handle, 1))
    report(%{phase: phase, observations: inspect(observations), application: "ready"})
  end

  defp exec(c, suffix, argv, options \\ []) do
    options = if options[:background], do: options, else: Keyword.put(options, :timeout_secs, 5)
    {:ok, command} = Command.new(argv, options)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: elem(c.handle, 0),
        id: elem(c.handle, 1) <> "-" <> suffix,
        artifact: c.base.artifact,
        profile: c.base.profile,
        command: command
      )

    {:ok, handle} = Machines.submit(c.runtime, c.handle, spec)
    {:ok, execution} = SmolBox.await(c.runtime, handle, 90_000)
    wait_machine(c.runtime, c.handle, &is_nil(&1.active_execution))
    execution.result
  end

  defp report(values), do: IO.puts(Jason.encode!(values))
end

ReadinessWalkthrough.run(List.first(System.argv()) || "healthy")
