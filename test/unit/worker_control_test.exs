defmodule SmolBox.WorkerControlTest do
  use ExUnit.Case, async: true
  alias SmolBox.Runtime.WorkerControls
  alias SmolBox.{WorkerControl, WorkerMaintenance}

  defmodule MalformedStore do
    def worker_control(reply, _worker), do: reply
  end

  test "invalid control histories and invalid changes cannot open admission" do
    initial = WorkerControl.initial("worker")

    for invalid <- [
          nil,
          %{},
          %{initial | worker_id: "bad/worker"},
          %{initial | mode: :draining},
          %{initial | version: -1},
          %{initial | version: 1},
          %{initial | version: 2, request_version: 0, updated_at_ms: 1000}
        ] do
      assert {:error, %{category: :validation}} = WorkerControl.validate(invalid)
      assert {:error, %{category: :validation}} = WorkerControl.admit(invalid)
    end

    for {mode, version, time} <- [
          {:active, :any, 1000},
          {:paused, 0, 1000},
          {:active, -1, 1000},
          {:draining, 0, -1}
        ] do
      assert {:error, %{category: :validation}} =
               WorkerControl.change(initial, mode, version, time)
    end

    {:ok, drained} = WorkerControl.change(initial, :draining, 0, 1000)
    {:ok, resumed} = WorkerControl.change(drained, :active, 1, 900)
    assert resumed.updated_at_ms == 1000
  end

  test "missing capability has no local fallback and malformed reads are unavailable" do
    legacy = %{worker_control: false, workers: [%{client: %{worker: %{id: "worker"}}}]}

    assert {:error, %{category: :unsupported_capability}} =
             WorkerControls.change(legacy, "worker", :draining, :any)

    assert {:error, %{category: :unsupported_capability}} =
             WorkerControls.maintenance(legacy, "worker", [])

    assert WorkerControls.mode(legacy, "worker") == :active
    assert WorkerControls.reports(legacy, [:unchanged]) == [:unchanged]

    for reply <- [
          nil,
          {:ok, %{}},
          {:ok, %{WorkerControl.initial("worker") | version: -1}},
          {:ok, WorkerControl.initial("other")}
        ] do
      config = %{worker_control: true, store: {MalformedStore, reply}}
      assert {:error, %{category: :store}} = WorkerControls.read(config, "worker")
      assert WorkerControls.mode(config, "worker") == :unavailable
    end

    assert WorkerMaintenance.valid_page?("worker", {2, "scope", "id"}, 1)
    refute WorkerMaintenance.valid_page?("worker", {3, "scope", "id"}, 1)
    refute WorkerMaintenance.valid_page?("worker", :invalid, 1)
  end
end
