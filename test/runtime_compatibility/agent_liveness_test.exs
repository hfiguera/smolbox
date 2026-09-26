defmodule SmolBox.AgentLivenessRuntimeTest do
  use ExUnit.Case, async: false

  alias SmolBox.{Client, Command, Identity, Machine, MachineSpec, Worker}
  @moduletag :runtime
  @moduletag timeout: 120_000

  test "three active streams do not hide machine liveness" do
    {:ok, endpoint} =
      Worker.new(
        "liveness-qualification",
        System.fetch_env!("SMOLBOX_RUNTIME_URL"),
        SmolBox.LabCandidate.endpoint_options(
          allow_insecure_loopback: true,
          operation_timeout_ms: 60_000,
          receive_timeout_ms: 55_000
        )
      )

    {:ok, client} = Client.new(endpoint)
    assert {:ok, %{version: "1.19.0"}} = Client.health(client)
    {:ok, name} = Identity.machine_name("liveness")
    {:ok, spec} = MachineSpec.new(name, System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"))
    assert {:ok, created} = Client.create(client, spec)

    try do
      assert {:ok, %{state: :running}} = Client.start(client, name)
      owner = self()

      # The client pool has four connections. Leave one for observations.
      # Managed machines still allow only one active command.
      tasks =
        for index <- 1..3 do
          Task.async(fn ->
            {:ok, command} =
              Command.new(
                ["python", "-c", "import time; print('ready', flush=True); time.sleep(15)"],
                timeout_secs: 25
              )

            Client.exec_stream(client, name, command,
              on_event: fn
                {:stdout, bytes} -> send(owner, {:started, index, bytes})
                _event -> :ok
              end
            )
          end)
        end

      for index <- 1..3 do
        assert_receive {:started, ^index, bytes}, 10_000
        assert bytes != ""
      end

      assert Enum.all?(tasks, &Process.alive?(&1.pid))
      assert {:ok, %{state: :running} = observed} = Client.inspect_machine(client, name)
      assert Machine.same_incarnation?(created, observed)
      assert {:ok, %{total: total, running: running}} = Client.health(client)
      assert total >= 1 and running >= 1
      assert :ok = Client.readiness(client)

      for task <- tasks do
        assert {:ok, %{exit_code: 0, stdout: "ready\n"}} = Task.await(task, 30_000)
      end
    after
      assert {:ok, observed} = Client.inspect_machine(client, name)
      assert Machine.same_incarnation?(created, observed)
      assert :ok = Client.delete(client, name)
      assert {:error, %{category: :not_found}} = Client.inspect_machine(client, name)
    end
  end
end
