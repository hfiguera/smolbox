defmodule SmolBox.WorkloadRuntimeTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Client, Command, Identity, Machine, MachineSpec, Worker, Workload}
  @moduletag :runtime
  @moduletag timeout: 180_000

  test "failed startup still reports VM running; console observation does not restart the app" do
    {:ok, endpoint} =
      Worker.new(
        "workload-failure",
        System.fetch_env!("SMOLBOX_RUNTIME_URL"),
        SmolBox.LabCandidate.endpoint_options(
          allow_insecure_loopback: true,
          operation_timeout_ms: 60_000,
          receive_timeout_ms: 55_000
        )
      )

    {:ok, client} = Client.new(endpoint)
    {:ok, workload} = Workload.new(entrypoint: ["/missing-workload-program"], cmd: [])

    {:ok, name} = Identity.machine_name("startup")

    {:ok, spec} =
      MachineSpec.new(
        name,
        System.fetch_env!("SMOLBOX_PYTHON_ARTIFACT"),
        workload: workload,
        storage_gb: 2,
        overlay_gb: 2
      )

    {:ok, created} = Client.create(client, spec)

    try do
      assert {:ok, %{state: :running} = running} = Client.start(client, created.name)
      assert Machine.same_incarnation?(created, running)
      assert {:ok, %{source: :console, lines: [_ | _]}} = Client.logs(client, created.name)

      {:ok, command} =
        Command.new(["python", "-c", "print('VM remains usable')"], timeout_secs: 5)

      assert {:ok, %{exit_code: 0, stdout: "VM remains usable\n"}} =
               Client.exec(client, created.name, command)

      assert {:ok, %{state: :running}} = Client.inspect_machine(client, created.name)
    after
      {:ok, observed} = Client.inspect_machine(client, created.name)
      assert Machine.same_incarnation?(created, observed)
      assert :ok = Client.delete(client, created.name)
      assert {:error, %{category: :not_found}} = Client.inspect_machine(client, created.name)
    end
  end
end
