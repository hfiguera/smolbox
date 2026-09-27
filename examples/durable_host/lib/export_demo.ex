defmodule SmolBox.DurableHost.ExportDemo do
  @moduledoc """
  Explicit prepare, confirm and reuse phases across separate BEAM invocations.
  See the example README for destination, credential and quiescence approvals.
  """
  alias SmolBox.{
    Client,
    Command,
    ExecutionSpec,
    Exports,
    ExportSpec,
    Machines,
    ManagedMachineSpec
  }

  alias SmolBox.DurableHost.{ExportDemoConfig, Store}
  import SmolBox.DurableHost.PersistentSteps, only: [lifecycle: 3, wait_machine: 3]

  def run(phase) when phase in ["prepare", "confirm", "reuse"] do
    context = ExportDemoConfig.start(phase)

    try do
      execute(phase, context)
    after
      Supervisor.stop(context.runtime)
    end
  end

  defp execute("prepare", context) do
    create(context, context.spec)

    command(
      context,
      context.spec,
      "write",
      ["/bin/sh", "-c", "mkdir -p /app; printf export-proof > /app/export-proof.txt"],
      ""
    )

    command(context, context.spec, "read", ["/bin/cat", "/app/export-proof.txt"], "export-proof")
    {:ok, _} = lifecycle(context.runtime, context.handle, :stop)
    wait_machine(context.runtime, context.handle, &(&1.state == :stopped))

    {:ok, request} =
      ExportSpec.new(
        id: "prepared",
        destination: context.destination,
        tag: context.spec.id,
        timeout_ms: 900_000
      )

    {:ok, handle} = Exports.submit(context.runtime, context.handle, request)
    {:ok, %{state: :published, result: result}} = Exports.await(context.runtime, handle, 900_000)

    IO.puts(
      Jason.encode!(%{
        phase: "published",
        result: Map.from_struct(result),
        cleanup_confirmation_required: true
      })
    )
  end

  defp execute("confirm", context) do
    # This is a host assertion, not evidence derived from the worker response.
    true = System.get_env("SMOLBOX_EXPORT_QUIESCED") == "true"
    {:ok, machine} = Machines.inspect(context.runtime, context.handle)

    {:ok, %{state: :completed}} =
      Exports.resolve(context.runtime, context.export_handle, machine.version, quiesced: true)

    {:ok, %{slots: 1}} = Store.usage(context.store, "export-demo-worker")

    IO.puts(
      Jason.encode!(%{
        phase: "confirmed",
        source_retained: true,
        helper_reservation_released: true
      })
    )
  end

  defp execute("reuse", context) do
    {:ok, %{state: :completed, result: result}} =
      Exports.fetch(context.runtime, context.export_handle)

    true = result.reference == System.fetch_env!("SMOLBOX_APPROVED_EXPORT_REFERENCE")

    {:ok, child} =
      ManagedMachineSpec.new(
        scope: context.spec.scope,
        id: context.spec.id <> "-copy",
        artifact: SmolBox.Source.artifact(context.copy_source),
        profile: context.spec.profile
      )

    create(context, child)
    command(context, child, "read-copy", ["/bin/cat", "/app/export-proof.txt"], "export-proof")

    command(
      context,
      child,
      "change-copy",
      ["/bin/sh", "-c", "printf changed-copy > /app/export-proof.txt"],
      ""
    )

    command(context, child, "verify-copy", ["/bin/cat", "/app/export-proof.txt"], "changed-copy")
    {:ok, _} = lifecycle(context.runtime, context.handle, :start)
    wait_machine(context.runtime, context.handle, &(&1.state == :running))

    command(
      context,
      context.spec,
      "verify-source",
      ["/bin/cat", "/app/export-proof.txt"],
      "export-proof"
    )

    Enum.each([context.spec, child], &delete(context, &1))
    {:ok, %{slots: 0, disk_gb: 0}} = Store.usage(context.store, "export-demo-worker")
    {:ok, %{result: ^result}} = Exports.fetch(context.runtime, context.export_handle)

    IO.puts(
      Jason.encode!(%{
        phase: "reused",
        file_preserved: true,
        independent_disks: true,
        absence_verified: true,
        reservations_released: true,
        retained_registry_reference: result.reference
      })
    )
  end

  defp create(context, spec) do
    {:ok, handle} = Machines.create(context.runtime, spec)
    machine = wait_machine(context.runtime, handle, &(&1.state in [:created, :running]))
    if machine.state == :created, do: lifecycle(context.runtime, handle, :start)
    wait_machine(context.runtime, handle, &(&1.state == :running))
  end

  defp command(context, machine, suffix, argv, expected) do
    {:ok, command} = Command.new(argv)

    {:ok, spec} =
      ExecutionSpec.new(
        scope: machine.scope,
        id: machine.id <> ":" <> suffix,
        artifact: machine.artifact,
        profile: machine.profile,
        command: command
      )

    handle = {machine.scope, machine.id}
    {:ok, execution} = Machines.submit(context.runtime, handle, spec)

    {:ok, %{state: :completed, result: %{exit_code: 0, stdout: ^expected}}} =
      SmolBox.await(context.runtime, execution, 120_000)

    wait_machine(context.runtime, handle, &is_nil(&1.active_execution))
  end

  defp delete(context, spec) do
    handle = {spec.scope, spec.id}
    {:ok, _} = lifecycle(context.runtime, handle, :delete)
    record = wait_machine(context.runtime, handle, &(&1.state == :deleted))

    {:error, %{category: :not_found}} =
      Client.inspect_machine(context.client, record.machine_name)
  end
end
