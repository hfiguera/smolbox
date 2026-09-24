defmodule WorkspaceWeb.WorkspaceLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Workspace.{Fixture, TestWorker}
  @endpoint WorkspaceWeb.Endpoint
  defp local_conn, do: Map.put(build_conn(), :host, "localhost")
  setup do: %{c: Fixture.start()}

  test "browser process disappearance retains the running machine", %{c: c} do
    id = Fixture.running(c)
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    assert has_element?(view, "#machine-id", id)
    assert has_element?(view, "#machine-state", "Running")
    GenServer.stop(view.pid, :normal)
    assert map_size(TestWorker.snapshot().machines) == 1

    assert {:ok, %{state: :running}} =
             SmolBox.Machines.inspect(Workspace.Settings.runtime(), {"workspace", id})

    {:ok, reconnected, _} = live(local_conn(), "/")
    render_async(reconnected)
    assert has_element?(reconnected, "#machine-id", id)
  end

  test "worker outage is visible and disables mutations", %{c: c} do
    Fixture.running(c)
    :sys.replace_state(Workspace.Connection, &%{&1 | status: :worker_or_store_unavailable})
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    assert has_element?(view, "#setup-title", "Connection needs attention")
    assert has_element?(view, "button[phx-click=stop][disabled]")
  end

  test "download paths survive updates and stale terminal warnings clear after recovery", %{c: c} do
    Fixture.running(c)
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    assert has_element?(view, "#download-form input[value='/app/project/starts.txt']")
    view |> form("#download-form", %{"path" => "/app/project/custom.txt"}) |> render_change()
    send(view.pid, :refresh)
    render_async(view)
    assert has_element?(view, "#download-form input[value='/app/project/custom.txt']")
    send(view.pid, {:terminal_closed, {:error, :lost}})
    assert has_element?(view, "#notice", "Terminal disconnected")
    send(view.pid, :refresh)
    render_async(view)
    assert has_element?(view, "#notice", "Workspace available")
    assert has_element?(view, "nav[aria-label='Workspace sections'] a[href='#shell']")
  end

  test "host checks and download identities reject unrelated requests" do
    conn = build_conn() |> Map.put(:host, "attacker.example") |> get("/")
    assert conn.status == 400
    conn = get(local_conn(), "/downloads/not-a-uuid")
    assert conn.status == 409
  end

  test "completed requests receive a concise accessible announcement", %{c: c} do
    id = Fixture.running(c)
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    token = Ecto.UUID.generate()

    assert {:ok, _} =
             Workspace.Workspaces.command(id, token, %{
               "command" => "echo hi",
               "workdir" => "/app/project",
               "mode" => "foreground",
               "timeout" => "30"
             })

    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :completed))
    send(view.pid, :refresh)
    render_async(view)

    assert has_element?(
             view,
             "#workspace-status[aria-live=polite][aria-atomic=true]",
             "Command Completed. Exit 0"
           )

    assert has_element?(view, ".service-panel h3", "Mapped service")
    assert has_element?(view, "#workspace-status", token)
    second = Ecto.UUID.generate()

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Workspace.Settings.runtime(), {"workspace", id}) end,
      &is_nil(&1.active_execution)
    )

    assert {:ok, _} =
             Workspace.Workspaces.command(id, second, %{
               "command" => "echo hi",
               "workdir" => "/app/project",
               "mode" => "foreground",
               "timeout" => "30"
             })

    Fixture.wait(fn -> Fixture.execution(second) end, &(&1.state == :completed))
    send(view.pid, :refresh)
    render_async(view)
    assert has_element?(view, "#workspace-status", second)
    refute has_element?(view, "#workspace-status", token)
  end
end
