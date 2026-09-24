defmodule Workspace.WorkspacesTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias SmolBox.DurableHost.Store
  alias Workspace.{Fixture, Ledger, Settings, TestWorker, Workspaces}
  setup do: %{c: Fixture.start()}

  defp params(text \\ "echo retained"),
    do: %{
      "command" => text,
      "workdir" => "/app/project",
      "mode" => "foreground",
      "timeout" => "30"
    }

  test "workspace identity and completed execution survive a fresh controller", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.command(id, token, params())
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :completed))

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &is_nil(&1.active_execution)
    )

    stop_supervised!(SmolBox.Runtime)
    start_supervised!({SmolBox.Runtime, c.options})
    assert {:ok, ^id} = Workspaces.create()
    assert {:ok, _} = Workspaces.command(id, token, params())
    assert {:ok, snapshot} = Workspaces.snapshot()
    assert snapshot.home.id == id
    assert [_] = TestWorker.snapshot().commands
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "concurrent duplicate submissions dispatch once and changed payload conflicts", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()

    results =
      1..6
      |> Task.async_stream(fn _ -> Workspaces.command(id, token, params()) end)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :completed))
    assert {:error, :identity_conflict} = Workspaces.command(id, token, params("echo different"))
    assert [_] = TestWorker.snapshot().commands
  end

  test "unknown execution blocks commands and lifecycle without replay or deletion", %{c: c} do
    id = Fixture.running(c)
    TestWorker.configure(lost_exec: true)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.command(id, token, params())
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :unknown))
    assert {:ok, _} = Workspaces.command(id, token, params())

    assert {:error, %{category: :admission_exhausted}} =
             Workspaces.command(id, Ecto.UUID.generate(), params())

    assert {:error, %{category: :admission_exhausted}} =
             Workspaces.lifecycle(:delete, id, Ecto.UUID.generate())

    assert {:error, %{category: :admission_exhausted}} =
             Workspaces.upload(id, Ecto.UUID.generate(), "/app/project/blocked.txt", "blocked")

    assert {:error, %{category: :admission_exhausted}} =
             Workspaces.collect(id, Ecto.UUID.generate(), "/app/project/blocked.txt")

    assert {:ok, _} = Workspaces.cancel(id, token)
    assert [_] = TestWorker.snapshot().commands
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "invalid working directories never prepare a receipt or dispatch", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()

    assert {:error, :workdir_policy} =
             Workspaces.command(id, token, Map.put(params(), "workdir", "/etc"))

    assert {:error, :not_found} = Ledger.action(c, token)
    assert TestWorker.snapshot().commands == []
  end

  test "submitted form restoration reads only the matching authorized receipt", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.command(id, token, params("echo restore-me"))
    assert {:ok, restored} = Workspaces.intent(token, "command")
    assert restored == params("echo restore-me")
    refute match?({:ok, _}, Workspaces.intent(token, "download"))
    assert {:error, :not_found} = Workspaces.intent(Ecto.UUID.generate(), "command")
    foreign = Ecto.UUID.generate()
    Ledger.reserve(c, foreign, Ecto.UUID.generate(), "command", params("other machine"))
    assert {:error, :not_found} = Workspaces.intent(foreign, "command")
  end

  test "missing files have a known failure, no download, and release the command slot", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.collect(id, token, "/app/project/missing")
    result = Fixture.wait(fn -> Fixture.execution(token) end, &(&1.collection == :complete))
    assert result.result.exit_code == 1
    assert result.state == :completed
    refute match?({:ok, _, _}, Workspaces.download(token))

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &is_nil(&1.active_execution)
    )

    assert {:ok, _} = Workspaces.command(id, Ecto.UUID.generate(), params())
    assert {:ok, same} = Workspaces.collect(id, token, "/app/project/missing")
    assert same.id == token
    assert {:error, :identity_conflict} = Workspaces.collect(id, token, "/app/project/different")
  end

  test "reserved collection path is rejected before upload or collection dispatch", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()

    assert {:error, :reserved_path} =
             Workspaces.upload(id, token, Workspace.Collection.path(), "data")

    assert {:error, :reserved_path} = Workspaces.collect(id, token, Workspace.Collection.path())
    assert {:error, :not_found} = Ledger.action(c, token)
    assert TestWorker.snapshot().commands == []
  end

  test "collection retries reuse pre-upgrade executions without changing their immutable spec", %{
    c: c
  } do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    path = "/app/project/old-download"
    machine_name = hd(Map.keys(TestWorker.snapshot().machines))

    TestWorker.configure(
      files: %{{machine_name, ["app", "project", "old-download"]} => "old bytes"}
    )

    Ledger.reserve(c, token, id, "download", %{"path" => path})
    {:ok, command} = SmolBox.Command.new(["/bin/true"], workdir: "/app/project", timeout_secs: 5)

    {:ok, spec} =
      SmolBox.ExecutionSpec.new(
        scope: Settings.scope(),
        id: token,
        artifact: c.artifact,
        profile: c.profile,
        command: command,
        retention_ms: 60_000,
        outputs: [
          %{"destination" => "download", "path" => path, "max_bytes" => Settings.max_file_bytes()}
        ]
      )

    assert {:ok, _} = SmolBox.Machines.submit(Settings.runtime(), Workspaces.handle(id), spec)
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.collection == :complete))
    assert {:ok, same} = Workspaces.collect(id, token, path)
    assert same.spec == spec
    assert {:ok, "old-download", "old bytes"} = Workspaces.download(token)
    assert [_] = TestWorker.snapshot().commands
  end

  test "uploads and collections use managed executions and enforce path and size approvals", %{
    c: c
  } do
    id = Fixture.running(c)

    assert {:error, :file_policy} =
             Workspaces.upload(id, Ecto.UUID.generate(), "/etc/profile", "bad")

    assert {:error, :file_policy} =
             Workspaces.upload(
               id,
               Ecto.UUID.generate(),
               "/app/project/a",
               :binary.copy(<<0>>, Settings.max_file_bytes() + 1)
             )

    bytes = :binary.copy(<<0, 255>>, 1_048_576)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.upload(id, token, "/app/project/large.bin", bytes)
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :completed))

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &is_nil(&1.active_execution)
    )

    download = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.collect(id, download, "/app/project/large.bin")
    Fixture.wait(fn -> Fixture.execution(download) end, &(&1.collection == :complete))
    assert {:ok, "large.bin", ^bytes} = Workspaces.download(download)

    assert {:error, :file_policy} =
             Workspaces.collect(id, Ecto.UUID.generate(), "/app/project/../secret")
  end

  test "delete verifies absence and releases reservations while keeping history", %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.lifecycle(:delete, id, token)

    deleted =
      Fixture.wait(
        fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
        &(&1.state == :deleted)
      )

    assert deleted.absence_at_ms != nil and deleted.reservation == nil

    assert {:ok, %{slots: 0, disk_gb: 0}} =
             Store.usage(c.store, "workspace-worker")

    assert TestWorker.snapshot().machines == %{}
    assert {:ok, ^id} = Workspaces.create()
    assert TestWorker.snapshot().machines == %{}
    assert {:ok, %{state: "submitted"}} = Ledger.action(c, token)
  end

  test "a lifecycle intent left between persistence and dispatch is not automatically replayed",
       %{c: c} do
    id = Fixture.running(c)
    token = Ecto.UUID.generate()
    assert {:ok, :inserted} = Ledger.reserve(c, token, id, "stop", %{"operation" => "stop"})
    assert {:ok, :already_recorded} = Workspaces.lifecycle(:stop, id, token)

    assert {:ok, %{state: :running}} =
             SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id))
  end

  test "request payloads are encrypted and bound to identity", %{c: c} do
    token = Ecto.UUID.generate()

    assert {:ok, :inserted} =
             Ledger.reserve(c, token, c.settings["workspace_id"], "command", %{
               "command" => "sensitive-marker"
             })

    %{rows: [[bytes]]} =
      SQL.query!(
        Workspace.Repo,
        "SELECT payload FROM workspace_actions WHERE partition=$1 AND id=$2",
        [c.store.partition, token]
      )

    refute String.contains?(bytes, "sensitive-marker")

    assert {:error, :identity_conflict} =
             Ledger.reserve(c, token, c.settings["workspace_id"], "command", %{
               "command" => "different"
             })
  end

  test "worker unavailability preserves machine identity and reservations", %{c: c} do
    id = Fixture.running(c)
    TestWorker.configure(unavailable: true)
    assert {:ok, snapshot} = Workspaces.snapshot()
    assert snapshot.home.id == id
    assert {:ok, %{slots: 1}} = snapshot.usage
    assert {:error, _} = Workspaces.logs(id)
  end

  test "store access failure prevents dispatch and does not erase workspace identity", %{c: c} do
    id = Fixture.running(c)
    Sandbox.mode(Workspace.Repo, :manual)
    assert {:error, :unavailable} = Workspaces.command(id, Ecto.UUID.generate(), params())
    assert {:error, :unavailable} = Workspaces.snapshot()
    assert TestWorker.snapshot().commands == []
    Sandbox.mode(Workspace.Repo, {:shared, c.sandbox_owner})
    assert c.settings["workspace_id"] == id
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "stopped machines keep disk reservations and can start again", %{c: c} do
    id = Fixture.running(c)
    assert {:ok, _} = Workspaces.lifecycle(:stop, id, Ecto.UUID.generate())

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &(&1.state == :stopped)
    )

    assert {:ok, %{disk_gb: 4, slots: 1}} = Store.usage(c.store, "workspace-worker")
    assert {:ok, _} = Workspaces.lifecycle(:start, id, Ecto.UUID.generate())

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &(&1.state == :running)
    )

    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "lifecycle completion requires the matching accepted request version", %{c: c} do
    id = Fixture.running(c)
    {:ok, before} = SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id))
    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.lifecycle(:stop, id, token)

    stopped =
      Fixture.wait(
        fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
        &(&1.state == :stopped)
      )

    assert {:ok, %{state: "submitted"}} = Ledger.action(c, token)
    Ledger.observe_lifecycle(c, %{stopped | last_request: {:stop, before.version - 1}})
    assert {:ok, %{state: "submitted"}} = Ledger.action(c, token)
    assert {:ok, _} = Workspaces.snapshot()
    assert {:ok, %{state: "completed"}} = Ledger.action(c, token)
    assert {:ok, _} = Workspaces.lifecycle(:start, id, Ecto.UUID.generate())
    assert {:ok, %{state: "completed"}} = Ledger.action(c, token)
  end

  test "foreground budgets and background PID evidence use the public command types", %{c: c} do
    id = Fixture.running(c)

    assert {:error, :invalid_command} =
             Workspaces.command(id, Ecto.UUID.generate(), Map.put(params(), "timeout", "601"))

    token = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.command(id, token, Map.put(params(), "timeout", "330"))
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :completed))

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Settings.runtime(), Workspaces.handle(id)) end,
      &is_nil(&1.active_execution)
    )

    background = Ecto.UUID.generate()
    assert {:ok, _} = Workspaces.command(id, background, Map.put(params(), "mode", "background"))
    record = Fixture.wait(fn -> Fixture.execution(background) end, &(&1.state == :launched))
    assert %SmolBox.LaunchResult{pid: 42} = record.result
    assert {:ok, _} = Workspaces.command(id, background, Map.put(params(), "mode", "background"))
    assert [_, _] = TestWorker.snapshot().commands
  end
end
