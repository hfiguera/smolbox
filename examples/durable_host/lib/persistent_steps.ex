defmodule SmolBox.DurableHost.PersistentSteps do
  @moduledoc false
  alias SmolBox.{Command, ExecutionSpec, Machines}

  def command(runtime, {scope, id} = handle, base, suffix, program, expected) do
    {:ok, command} = Command.new(["python", "-c", program], timeout_secs: 5)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: scope,
        id: id <> "-" <> suffix,
        artifact: base.artifact,
        profile: base.profile,
        command: command
      )

    {:ok, execution} = Machines.submit(runtime, handle, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: ^expected}}} =
      SmolBox.await(runtime, execution, 90_000)

    wait_machine(runtime, handle, &is_nil(&1.active_execution))
  end

  def lifecycle(runtime, handle, operation),
    do: lifecycle(runtime, handle, operation, System.monotonic_time(:millisecond) + 5_000)

  defp lifecycle(runtime, handle, operation, deadline) do
    {:ok, machine} = Machines.inspect(runtime, handle)

    case apply(Machines, operation, [runtime, handle, machine.version]) do
      {:error, %{category: :stale_version, evidence: :not_dispatched}} = error ->
        # Reconciliation can update the version after inspection. Only retry a
        # rejected store conflict, never an uncertain worker mutation.
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          lifecycle(runtime, handle, operation, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  def wait_machine(runtime, handle, predicate, timeout \\ 90_000),
    do: observe(runtime, handle, predicate, System.monotonic_time(:millisecond) + timeout)

  defp observe(runtime, handle, predicate, deadline) do
    {:ok, record} = Machines.inspect(runtime, handle)

    cond do
      predicate.(record) ->
        record

      record.state in [:unknown, :missing, :conflict] ->
        raise "machine requires resolution: #{inspect(record)}"

      System.monotonic_time(:millisecond) >= deadline ->
        raise "machine observation deadline: #{inspect(record)}"

      true ->
        Process.sleep(50)
        observe(runtime, handle, predicate, deadline)
    end
  end

  # This demo requires resize2fs-capable workers and keeps disk requests
  # small. Operators must qualify these floors for their prepared image.
  def small_profile(options, base) do
    profile = %{base.profile | id: "persistent-demo-v1", storage_gb: 2, overlay_gb: 2}

    workers =
      Enum.map(options[:workers], fn worker ->
        %{
          worker
          | profiles: [profile],
            allocation_floor: %{storage_gb: 2, overlay_gb: 2, host_overhead_mb: 768},
            capacity: %{slots: 1, cpus: 1, memory_mb: 1024, disk_gb: 4}
        }
      end)

    {Keyword.put(options, :workers, workers), %{base | profile: profile}}
  end
end
