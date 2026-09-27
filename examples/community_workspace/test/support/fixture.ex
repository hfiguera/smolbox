defmodule Workspace.Fixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Ecto.Adapters.SQL.Sandbox
  alias SmolBox.Runtime
  alias Workspace.{Settings, Workspaces}

  def start(options \\ []) do
    owner = Sandbox.start_owner!(Workspace.Repo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(owner) end)
    root = Path.join(System.tmp_dir!(), "workspace-test-" <> Ecto.UUID.generate())
    File.mkdir_p!(Path.join(root, "objects"))
    File.chmod!(Path.join(root, "objects"), 0o700)
    image = Path.join(root, "image.smolmachine")
    File.write!(image, "simulated image")
    old_home = Settings.home()
    Application.put_env(:community_workspace, :home, root)

    s = %{
      "image_path" => image,
      "image_sha256" => Settings.digest(image),
      "worker_url" => "http://127.0.0.1:19470",
      "architecture" => "x86_64",
      "platform" => "linux",
      "partition" => "test-" <> Ecto.UUID.generate(),
      "workspace_id" => Ecto.UUID.generate(),
      "preview_url" => "http://127.0.0.1:18080/",
      "service_port" => 18_080,
      "fingerprint" => :crypto.strong_rand_bytes(32),
      "encryption" => :crypto.strong_rand_bytes(32)
    }

    s = Map.put(s, "runtime_version", "1.19.0")

    s =
      if options[:saved_state] do
        root |> Path.join("captures") |> File.mkdir_p!()
        root |> Path.join("captures") |> File.chmod!(0o700)
        seed = Path.join(root, "seed.smolcheckpoint")
        File.write!(seed, "simulated seed")
        Map.put(s, "saved_state", %{"path" => seed, "sha256" => Settings.digest(seed)})
      else
        s
      end

    {:ok, c} = Settings.build(s)
    ExUnit.Callbacks.start_supervised!(Workspace.TestWorker)
    client = %{c.client | transport: Workspace.TestWorker}
    [worker] = c.options[:workers]
    options = Keyword.put(c.options, :workers, [%{worker | client: client}])
    c = %{c | client: client, options: options}
    ExUnit.Callbacks.start_supervised!({SmolBox.Runtime, options})
    :sys.replace_state(Workspace.Connection, fn _ -> %{context: c, status: :ready} end)

    ExUnit.Callbacks.on_exit(fn ->
      :sys.replace_state(Workspace.Connection, fn _ ->
        %{context: nil, status: :setup_required}
      end)

      Application.put_env(:community_workspace, :home, old_home)
      File.rm_rf!(root)
    end)

    Map.put(c, :sandbox_owner, owner)
  end

  def running(c) do
    {:ok, id} = Workspaces.create()

    wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &(&1.state == :created)
    )

    assert {:ok, _} = Workspaces.lifecycle(:start, id, Ecto.UUID.generate())

    wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &(&1.state == :running)
    )

    assert id == c.settings["workspace_id"]
    id
  end

  def wait(fetch, predicate, deadline \\ System.monotonic_time(:millisecond) + 8000) do
    {:ok, value} = fetch.()

    if predicate.(value),
      do: value,
      else:
        (
          assert(System.monotonic_time(:millisecond) < deadline, inspect(Map.from_struct(value)))
          Process.sleep(10)
          wait(fetch, predicate, deadline)
        )
  end

  # Killing a borrower inside an SQL Sandbox transaction disconnects its shared
  # connection and rolls back the test's durable state. Pause dispatch, then let
  # existing runtime tasks return the connection before a simulated restart.
  def stop_runtime do
    coordinator = Runtime.coordinator(Settings.runtime())
    :ok = :sys.suspend(coordinator)
    %{tasks: tasks} = :sys.get_state(coordinator)
    await_tasks(tasks, System.monotonic_time(:millisecond) + 5000)
    ExUnit.Callbacks.stop_supervised!(Runtime)
  end

  defp await_tasks(tasks, deadline) do
    case Task.Supervisor.children(tasks) do
      [] ->
        :ok

      children ->
        assert System.monotonic_time(:millisecond) < deadline,
               "runtime tasks did not finish before sandbox restart: #{inspect(children)}"

        Process.sleep(10)
        await_tasks(tasks, deadline)
    end
  end

  def execution(token), do: SmolBox.fetch(Settings.runtime(), Settings.scope(), token)
end
