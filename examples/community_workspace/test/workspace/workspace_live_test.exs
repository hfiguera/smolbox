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

  test "samples restore their working directory and known validation errors stay out of history",
       %{c: c} do
    Fixture.running(c)
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)

    form(view, "#command-form", %{
      "command" => "pwd",
      "workdir" => "/home/dev",
      "mode" => "foreground",
      "timeout" => "30"
    })
    |> render_change()

    element(view, "button[phx-click=sample][phx-value-index='1']") |> render_click()
    assert has_element?(view, "input[name=workdir][value='/app/project']")

    form(view, "#command-form", %{
      "command" => "pwd",
      "workdir" => "/etc",
      "mode" => "foreground",
      "timeout" => "30"
    })
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#notice", "No command was submitted")
    refute has_element?(view, ".activity", "Acceptance is unresolved")
  end

  test "unknown work shows recovery guidance instead of suggesting a reconnect", %{c: c} do
    id = Fixture.running(c)
    TestWorker.configure(lost_exec: true)
    token = Ecto.UUID.generate()

    Workspace.Workspaces.command(id, token, %{
      "command" => "pwd",
      "workdir" => "/app/project",
      "mode" => "foreground",
      "timeout" => "30"
    })

    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.state == :unknown))

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Workspace.Settings.runtime(), {"workspace", id}) end,
      &(&1.state == :unknown)
    )

    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    assert has_element?(view, "#shell", "Reconnection is no longer available")
    refute has_element?(view, "#shell", "The terminal is open in another tab")
  end

  test "download links keep the live page and failed collections expose no link", %{c: c} do
    id = Fixture.running(c)

    TestWorker.configure(
      files: %{
        {hd(Map.keys(TestWorker.snapshot().machines)), ["app", "project", "ok"]} => "bytes"
      }
    )

    token = Ecto.UUID.generate()
    Workspace.Workspaces.collect(id, token, "/app/project/ok")
    Fixture.wait(fn -> Fixture.execution(token) end, &(&1.collection == :complete))
    {:ok, view, _} = live(local_conn(), "/")
    render_async(view)
    assert has_element?(view, "#action-#{token} a[download]")

    Fixture.wait(
      fn -> SmolBox.Machines.inspect(Workspace.Settings.runtime(), {"workspace", id}) end,
      &is_nil(&1.active_execution)
    )

    missing = Ecto.UUID.generate()
    Workspace.Workspaces.collect(id, missing, "/app/project/missing")
    Fixture.wait(fn -> Fixture.execution(missing) end, &(&1.collection == :complete))
    send(view.pid, :refresh)
    render_async(view)
    refute has_element?(view, "#action-#{missing} a")
    assert has_element?(view, "#action-#{missing}", "File not collected")
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
