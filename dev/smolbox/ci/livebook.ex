defmodule SmolBox.CI.Livebook do
  @moduledoc false
  alias SmolBox.CI.{Child, HTTP, Package, Preflight, Runtime, Util}

  @root Path.expand("../../..", __DIR__)
  @version "0.19.10"
  @notebook "docs/notebooks/getting-started.livemd"
  @checks ~w(execution stdout collection cleanup reservation inventory supervisor)

  def run(arguments) do
    {options, []} =
      Util.options!(
        arguments,
        [
          url: :string,
          worker_pid: :integer,
          python: :string,
          sha256: :string,
          livebook: :string,
          report: :string,
          archive: :string,
          published: :boolean
        ],
        [:url, :worker_pid, :python, :sha256, :livebook, :report]
      )

    # Reserve before any process or VM is started, including concurrent invocations.
    Util.write_json!(options[:report], %{status: "failed", phase: "starting"})
    workspace = Util.temporary("smolbox-livebook")
    {:ok, children} = Agent.start_link(fn -> [] end)

    report =
      try do
        verify_worker!(options)
        source = File.read!(Path.join(@root, @notebook))
        demo = Path.join(workspace, "demo")
        File.mkdir_p!(Path.join(demo, "images"))
        File.mkdir!(Path.join(demo, "objects"))

        for directory <- [demo, Path.join(demo, "images"), Path.join(demo, "objects")],
            do: File.chmod!(directory, 0o700)

        File.cp!(options[:python], Path.join(demo, "images/python.smolmachine"))
        {package, package_sha} = package!(options, workspace)
        notebook = configure!(source, demo, options[:sha256], options[:url], package)
        File.write!(Path.join(workspace, "notebook.livemd"), notebook <> probe())
        environment = environment(workspace)

        launch!(
          children,
          ["epmd", "-port", environment["ERL_EPMD_PORT"], "-address", "127.0.0.1"],
          environment
        )

        server = launch!(children, [Path.expand(options[:livebook]), "server"], environment)
        ready!(server, "http://127.0.0.1:" <> environment["LIVEBOOK_PORT"] <> "/public/health")

        {output, controller} =
          Child.execute(["elixir", Path.join(@root, "scripts/ci/livebook_rpc.exs")],
            env: Map.to_list(environment),
            timeout: 510_000
          )

        File.write!(Path.join(workspace, "controller.log"), output)
        evaluation = Util.json!(Path.join(workspace, "evaluation.json"))
        validate_result!(evaluation)
        Util.ensure!(controller.status == "passed", "Livebook controller failed")
        verify_worker!(options)

        Map.merge(evaluation, %{
          "status" => "passed",
          "mode" => if(package, do: "candidate", else: "published"),
          "platform" => Util.platform(),
          "worker_version" => "1.22.0",
          "notebook_sha256" => hash(source),
          "configured_notebook_sha256" => hash(notebook <> probe()),
          "python_sha256" => options[:sha256],
          "package_sha256" => package_sha,
          "controller" => controller
        })
      rescue
        error ->
          # Details belong in the private workspace, never the uploaded JSON.
          File.write!(
            Path.join(workspace, "failure.log"),
            Exception.format(:error, error, __STACKTRACE__)
          )

          evaluation = read_evaluation(workspace)
          Map.merge(evaluation, %{"status" => "failed", "platform" => Util.platform()})
      after
        stop_children(children, workspace)
      end

    stopped = Agent.get(children, &(&1 == []))
    Agent.stop(children)
    report = Map.put(report, "owned_processes_stopped", stopped)
    File.write!(options[:report], [JSON.encode!(report), "\n"])
    IO.puts("Livebook #{report["status"]}: #{options[:report]} (private evidence: #{workspace})")
    Util.ensure!(report["status"] == "passed" and stopped, "public Livebook verification failed")
  end

  def configure!(source, demo, digest, url, package) do
    dependency = Regex.scan(~r/^Mix\.install\(\[\{:smolbox, "[^"]+"\}\]\)$/m, source)
    Util.ensure!(match?([[_]], dependency), "expected one public SmolBox dependency cell")
    [[install]] = dependency

    source =
      if package,
        do:
          replace_once!(source, install, "Mix.install([{:smolbox, path: #{inspect(package)}}])"),
        else: source

    source
    |> replace_once!(
      ~s(demo_root = "/absolute/path/printed/by/setup"),
      "demo_root = #{inspect(demo)}"
    )
    |> replace_once!(
      ~s(approved_sha256 = "paste_the_sha256_printed_by_setup"),
      "approved_sha256 = #{inspect(digest)}"
    )
    |> replace_once!(~s(runtime_url = "http://127.0.0.1:19471"), "runtime_url = #{inspect(url)}")
  end

  def validate_result!(result) do
    cells = result["cells"]

    Util.ensure!(
      result["status"] == "passed" and result["livebook_version"] == @version and
        result["runtime"] == "Elixir.Livebook.Runtime.Standalone",
      "unexpected Livebook version or runtime"
    )

    Util.ensure!(
      result["import_warnings"] == [] and result["export_warnings"] == [],
      "Livebook import/export warnings"
    )

    validate_cells!(cells)

    Util.ensure!(
      is_map(result["checks"]) and Enum.all?(@checks, &(result["checks"][&1] === true)),
      "execution, output collection or cleanup was not verified"
    )
  end

  defp validate_cells!(cells) do
    Util.ensure!(
      is_list(cells) and Enum.count_until(cells, 6) == 6 and
        length(Enum.uniq_by(cells, & &1["id"])) == length(cells) and
        Enum.all?(
          cells,
          &(&1["validity"] == "evaluated" and &1["status"] == "ready" and &1["errored"] == false)
        ),
      "Livebook cells failed or were skipped"
    )
  end

  defp replace_once!(source, old, new) do
    Util.ensure!(
      match?([_], :binary.matches(source, old)),
      "notebook configuration changed; review verifier"
    )

    String.replace(source, old, new, global: false)
  end

  defp probe do
    """

    ## Automated verification

    ```elixir
    %{state: :completed, result: %{exit_code: 0}, collection: :complete,
      cleanup: :complete, reservation: nil} = cleaned
    true = record.result.stdout == "hello from SmolBox\\n"
    {:ok, "42\\n"} = Directory.read_output(objects, handle, "answer", 1024)
    {:ok, []} = SmolBox.Client.list(client)
    false = Process.alive?(supervisor)
    checks = %{execution: true, stdout: true, collection: true, cleanup: true,
      reservation: true, inventory: true, supervisor: true}
    IO.puts("SMOLBOX_LIVEBOOK_RESULT=" <> Jason.encode!(checks))
    ```
    """
  end

  defp verify_worker!(options) do
    url = options[:url]
    uri = URI.parse(url)

    Util.ensure!(
      Regex.match?(~r/\Ahttp:\/\/127\.0\.0\.1:[0-9]{1,5}\z/, url) and uri.port in 1..65_535,
      "expected loopback worker URL"
    )

    platform = Util.platform()
    {architecture, pin} = Runtime.pin!(platform, "1.22.0")

    Util.ensure!(
      String.trim(Util.command!(["uname", "-m"])) == architecture,
      "unsupported host architecture"
    )

    Preflight.listener!(options[:worker_pid], uri.port, platform)
    executable = Preflight.executable!(options[:worker_pid], platform)
    Util.ensure!(Util.digest(executable) == pin, "worker differs from pinned release")
    Preflight.wrapper!(executable, platform, "1.22.0")

    artifact = File.lstat!(options[:python])

    Util.ensure!(
      Path.type(options[:python]) == :absolute and artifact.type == :regular and
        artifact.size in 1..8_589_934_592 and Regex.match?(~r/\A[0-9a-f]{64}\z/, options[:sha256]),
      "expected bounded Python artifact and approved digest"
    )

    Util.ensure!(
      Util.digest(options[:python]) == options[:sha256],
      "Python artifact digest differs"
    )

    Util.ensure!(
      HTTP.json!(url <> "/health", "GET", nil, 4096)["version"] == "1.22.0",
      "wrong worker version"
    )

    Util.ensure!(
      HTTP.request(url <> "/readyz", "GET", nil, 4096) == {200, ""},
      "worker is not ready"
    )

    Util.ensure!(
      HTTP.json!(url <> "/api/v1/machines", "GET", nil, 4096) == %{"machines" => []},
      "worker inventory must be empty"
    )
  end

  defp package!(options, workspace) do
    if options[:published] do
      Util.ensure!(!options[:archive], "published mode cannot use candidate archive")
      {nil, nil}
    else
      archive = Path.join(workspace, "candidate.tar")

      if input = options[:archive] do
        File.cp!(input, archive)
      else
        Util.command!(["mix", "hex.build", "--output", archive],
          cd: @root,
          env: [{"MIX_ENV", "dev"}]
        )
      end

      package = Path.join(workspace, "candidate")
      Package.unpack!(archive, package)

      Util.ensure!(
        File.read!(Path.join(package, @notebook)) == File.read!(Path.join(@root, @notebook)),
        "package notebook differs from public source"
      )

      {package, Util.digest(archive)}
    end
  end

  defp environment(workspace) do
    File.mkdir!(Path.join(workspace, "livebook-data"))

    node =
      "smolboxlb" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower) <> "@127.0.0.1"

    cookie = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    File.write!(Path.join(workspace, "cookie"), cookie)
    File.chmod!(Path.join(workspace, "cookie"), 0o600)
    ports = Enum.map(1..3, fn _ -> free_port() end)
    Util.ensure!(Enum.uniq(ports) == ports, "private port collision; retry")
    [epmd, server, iframe] = Enum.map(ports, &to_string/1)

    reset =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "LIVEBOOK_"))
      |> Enum.map(&{&1, nil})

    Map.new(
      reset ++
        [
          {"ERL_EPMD_PORT", epmd},
          {"LIVEBOOK_PORT", server},
          {"LIVEBOOK_IFRAME_PORT", iframe},
          {"LIVEBOOK_IP", "127.0.0.1"},
          {"LIVEBOOK_NODE", node},
          {"LIVEBOOK_COOKIE", cookie},
          {"LIVEBOOK_DATA_PATH", Path.join(workspace, "livebook-data")},
          {"LIVEBOOK_HOME", workspace},
          {"LIVEBOOK_DEFAULT_RUNTIME", "standalone"},
          {"SMOLBOX_LIVEBOOK_WORKSPACE", workspace},
          {"SMOLBOX_LIVEBOOK_NODE", node},
          {"SMOLBOX_LIVEBOOK_EVALUATOR", Path.join(@root, "scripts/ci/livebook_evaluate.exs")},
          {"MIX_ENV", nil},
          {"MIX_DEPS_PATH", nil},
          {"MIX_BUILD_PATH", nil},
          {"MIX_INSTALL_DIR", Path.join(workspace, "mix-install")}
        ]
    )
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp launch!(children, arguments, environment) do
    {:ok, child} = Child.start_link(arguments, env: Map.to_list(environment), timeout: 600_000)
    Agent.update(children, &[child | &1])
    child
  end

  defp ready!(child, url) do
    deadline = System.monotonic_time(:millisecond) + 45_000
    wait_ready(child, url, deadline)
  end

  defp wait_ready(child, url, deadline) do
    {_, status} = Child.snapshot(child)

    Util.ensure!(
      is_nil(status.exit_code) and is_nil(status.failure),
      "Livebook exited before readiness"
    )

    ready =
      try do
        match?({200, _}, HTTP.request(url, "GET", nil, 4096))
      rescue
        _ -> false
      end

    unless ready do
      Util.ensure!(System.monotonic_time(:millisecond) < deadline, "Livebook readiness timed out")
      Process.sleep(200)
      wait_ready(child, url, deadline)
    end
  end

  defp stop_children(children, workspace) do
    children
    |> Agent.get(& &1)
    |> Enum.with_index()
    |> Enum.each(fn {child, index} ->
      {output, _} = Child.stop(child)
      File.write!(Path.join(workspace, "process-#{index}.log"), output)
      GenServer.stop(child)
    end)

    Agent.update(children, fn _ -> [] end)
    File.rm(Path.join(workspace, "cookie"))
  end

  defp read_evaluation(workspace) do
    case File.read(Path.join(workspace, "evaluation.json")) do
      {:ok, bytes} when byte_size(bytes) <= 65_536 -> JSON.decode!(bytes)
      _ -> %{}
    end
  end

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
