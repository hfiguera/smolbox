defmodule Workspace.SavedStateTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias SmolBox.{Machines, Runtime}
  alias Workspace.{Fixture, SavedState, Settings, TestWorker}
  @endpoint WorkspaceWeb.Endpoint
  setup do: %{c: Fixture.start(saved_state: true)}

  test "prepare, capture, branch and compare survive restart with retained cleanup accounting", %{
    c: c
  } do
    prepared(c)
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("capture")
    assert {:ok, _} = SavedState.act("capture", true)
    wait(c, &match?(%{state: :captured}, &1.capture))
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("branch", true)
    assert {:ok, _} = SavedState.act("confirm-capture", true)
    wait(c, &SavedState.allowed?(&1, "branch"))
    assert {:ok, _} = SavedState.act("branch", true)
    wait(c, &SavedState.allowed?(&1, "change"))
    assert {:ok, _} = SavedState.act("change")
    wait(c, &SavedState.allowed?(&1, "compare"))
    assert {:ok, _} = SavedState.act("compare")

    s =
      wait(
        c,
        &(SavedState.success?(&1.commands["read-original"]) and
            SavedState.success?(&1.commands["read-branch"]))
      )

    assert SavedState.output(s.commands["read-original"]) =~ "basil and lemon"
    assert SavedState.output(s.commands["read-branch"]) =~ "ginger and lime"
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("change")
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("delete-source", true)
    stop_supervised!(Runtime)
    start_supervised!({Runtime, c.options})
    assert {:ok, restored} = SavedState.snapshot(c)
    assert restored.source.id == s.source.id
    assert restored.capture.result == s.capture.result
    assert restored.commands == s.commands
    assert {:ok, view, _} = live(Map.put(build_conn(), :host, "localhost"), "/")
    render_async(view)
    assert has_element?(view, "#saved-state", "Both reads complete")
    assert has_element?(view, "#saved-state", "basil and lemon")
    assert has_element?(view, "#saved-state", "ginger and lime")
    assert has_element?(view, "#saved-cleanup", "never delete host files")
    GenServer.stop(view.pid)
    wait(c, &SavedState.allowed?(&1, "delete-child"))
    assert {:ok, _} = SavedState.act("delete-child", true)
    wait(c, &SavedState.allowed?(&1, "retire-child"))
    assert {:ok, _} = SavedState.act("retire-child", true)
    wait(c, &SavedState.allowed?(&1, "delete-source"))
    assert {:ok, _} = SavedState.act("delete-source", true)
    s = wait(c, &SavedState.allowed?(&1, "release-backing"))
    assert {:ok, %{slots: 1, disk_gb: disk}} = s.usage
    assert disk > 8
    assert {:error, _} = SavedState.act("release-capture", true)
    assert {:ok, _} = SavedState.act("release-backing", true)
    File.rm!(s.capture.result.path)
    assert {:ok, _} = SavedState.act("release-capture", true)
    assert {:ok, final} = SavedState.snapshot(c)
    assert {:ok, %{slots: 0, disk_gb: 0}} = final.usage
    assert final.capture.released_at_ms
    assert final.child.branch.state == :closed
    refute SavedState.allowed?(final, "create")
  end

  test "lost capture stays unknown after restart and cannot be repeated under another identity",
       %{c: c} do
    prepared(c)
    TestWorker.configure(lost_capture: true)
    assert {:ok, _} = SavedState.act("capture", true)
    wait(c, &match?(%{state: :unknown}, &1.capture))
    stop_supervised!(Runtime)
    start_supervised!({Runtime, c.options})
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("capture", true)
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("branch", true)
    assert {:error, :saved_state_action_not_allowed} = SavedState.act("delete-source", true)
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "a lost branch response retains its identity and blocks subsequent work", %{c: c} do
    prepared(c)
    assert {:ok, _} = SavedState.act("capture", true)
    wait(c, &match?(%{state: :captured}, &1.capture))
    assert {:ok, _} = SavedState.act("confirm-capture", true)
    wait(c, &SavedState.allowed?(&1, "branch"))
    TestWorker.configure(lost_branch: true)
    assert {:ok, _} = SavedState.act("branch", true)
    s = wait(c, &match?(%{branch: %{state: :unknown}}, &1.child))
    assert {:ok, %{disk_gb: disk}} = s.usage
    assert disk >= 13
    stop_supervised!(Runtime)
    start_supervised!({Runtime, c.options})

    for action <- ~w(branch change compare delete-source delete-child) do
      assert {:error, :saved_state_action_not_allowed} = SavedState.act(action, true)
    end

    assert map_size(TestWorker.snapshot().machines) == 2
  end

  test "unavailable controller cannot be mistaken for an empty walkthrough", %{c: c} do
    prepared(c)
    stop_supervised!(Runtime)
    assert {:error, _} = SavedState.snapshot(c)
    assert {:error, _} = SavedState.act("create")
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "store failures block actions while preserving recorded ownership", %{c: c} do
    prepared(c)
    Sandbox.mode(Workspace.Repo, :manual)
    assert {:error, _} = SavedState.snapshot(c)
    assert {:error, _} = SavedState.act("capture", true)
    Sandbox.mode(Workspace.Repo, {:shared, c.sandbox_owner})
    assert map_size(TestWorker.snapshot().machines) == 1
  end

  test "preparation deduplicates simultaneous clicks and does not mutate the ordinary workspace",
       %{c: c} do
    ordinary = Fixture.running(c)
    create_running(c)
    tasks = for _ <- 1..2, do: Task.async(fn -> SavedState.act("prepare") end)
    Enum.each(tasks, &Task.await/1)
    wait(c, &SavedState.allowed?(&1, "capture"))
    assert [_] = TestWorker.snapshot().commands

    assert {:ok, %{state: :running}} =
             Machines.inspect(Settings.runtime(), {Settings.scope(), ordinary})

    assert {:error, :saved_state_action_not_allowed} = SavedState.act("unrecognized")
  end

  test "confirmation is required server side and visible in the browser", %{c: c} do
    prepared(c)
    {:ok, view, _} = live(Map.put(build_conn(), :host, "localhost"), "/")
    render_async(view)
    assert has_element?(view, "#saved-capture input[type=checkbox][required]")
    render_submit(view, "saved-state", %{"action" => "capture"})
    render_async(view)
    assert {:ok, %{capture: nil}} = SavedState.snapshot(c)
    assert has_element?(view, "#saved-state", "not allowed")
  end

  defp create_running(c) do
    assert {:ok, _} = SavedState.act("create")
    wait(c, &SavedState.allowed?(&1, "start"))
    assert {:ok, _} = SavedState.act("start")
    wait(c, &SavedState.allowed?(&1, "prepare"))
  end

  defp prepared(c) do
    create_running(c)
    assert {:ok, _} = SavedState.act("prepare")
    wait(c, &SavedState.allowed?(&1, "capture"))
  end

  defp wait(c, predicate, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    {:ok, s} = SavedState.snapshot(c)

    if predicate.(s) do
      s
    else
      assert System.monotonic_time(:millisecond) < deadline,
             inspect(
               %{
                 source: Map.take(s.source || %{}, [:state, :last_error, :active_execution]),
                 commands:
                   Map.new(s.commands, fn {k, v} ->
                     {k, if(v, do: Map.take(v, [:state, :last_error, :result]), else: nil)}
                   end),
                 capture: s.capture
               },
               limit: :infinity
             )

      Process.sleep(20)
      wait(c, predicate, deadline)
    end
  end
end
