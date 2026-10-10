defmodule Workspace.ConnectionTest do
  use ExUnit.Case, async: false
  alias Workspace.{Connection, Fixture, Settings, TestWorker}

  setup do: %{c: Fixture.start()}

  test "refresh restores an absent runtime from its existing durable context", %{c: c} do
    Fixture.stop_runtime()
    assert Process.whereis(Settings.runtime()) == nil
    Connection.refresh()
    assert Connection.status() == :ready
    runtime = Process.whereis(Settings.runtime())
    assert is_pid(runtime)

    on_exit(fn -> DynamicSupervisor.terminate_child(Workspace.Runtimes, runtime) end)
    assert {:ok, context} = Connection.context()
    assert context.settings == c.settings
    assert context.store == c.store
    Connection.refresh()
    assert Connection.status() == :ready
    assert Process.whereis(Settings.runtime()) == runtime
    assert [_] = DynamicSupervisor.which_children(Workspace.Runtimes)
  end

  test "worker failure cannot report an absent runtime as ready" do
    Fixture.stop_runtime()
    TestWorker.configure(unavailable: true)
    Connection.refresh()
    assert Connection.status() == :worker_or_store_unavailable
    assert Process.whereis(Settings.runtime()) == nil
  end

  test "a failed runtime start cannot report ready", %{c: c} do
    Fixture.stop_runtime()

    context = %{
      Map.delete(c, :sandbox_owner)
      | options: Keyword.put(c.options, :fingerprint_key, "invalid")
    }

    :sys.replace_state(Connection, fn state -> %{state | context: context} end)
    Connection.refresh()
    assert Connection.status() == :worker_or_store_unavailable
    assert Process.whereis(Settings.runtime()) == nil
  end
end
