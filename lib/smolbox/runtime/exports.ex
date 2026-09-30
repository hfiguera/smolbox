defmodule SmolBox.Runtime.Exports do
  @moduledoc false
  alias SmolBox.{
    Client,
    Error,
    ExportReceipt,
    ManagedMachine,
    RegistryCredentials,
    RegistryExport
  }

  alias SmolBox.Runtime.MachineSession, as: Machines
  alias SmolBox.Runtime.{Session, WorkerHealth}

  def run(config, machine) do
    export = machine.exports[machine.active_export]

    case export.state do
      :accepted ->
        prepare(config, machine, export)

      :dispatching ->
        unknown(config, machine, export, %Error{category: :unknown, operation: :export})

      :verifying ->
        verify(config, machine, export)

      state when state in [:unknown, :published] ->
        Machines.write(config, machine, next_due_at_ms: config.clock.now() + 60_000)
    end
  end

  def advance(config, machine, export, changes) do
    with {:ok, current} <- Machines.claim(config, ManagedMachine.key(machine)),
         do:
           Machines.store(config, :export_advance, [
             ManagedMachine.key(machine),
             Session.guard(current),
             export.spec.id,
             export.state,
             changes,
             config.clock.now()
           ])
  end

  def approved?(worker, spec) do
    worker.runtime_version in ["1.19.0", "1.20.2"] and
      spec.destination in worker.export_destinations
  end

  defp prepare(config, machine, export) do
    result = Machines.io(config, machine, fn -> preflight(config, machine, export) end)

    case result do
      :ok ->
        dispatch(config, machine, export)

      {:error, error} ->
        advance(config, machine, export, state: :failed, error: error)

      _invalid ->
        advance(config, machine, export,
          state: :failed,
          error: %Error{category: :protocol, operation: :export}
        )
    end
  end

  defp preflight(config, machine, export) do
    with {:ok, worker} <- Machines.worker(config, machine),
         true <- approved?(worker, export.spec),
         %{status: :ready} <- WorkerHealth.observe(worker, config.clock),
         {:ok, observed} <- Client.inspect_machine(worker.client, machine.machine_name),
         true <-
           observed.state == :stopped and
             SmolBox.DiskExpansion.matches?(machine, observed),
         {:ok, token} <-
           RegistryCredentials.publication(
             worker.registry_credentials,
             export.spec.destination.credential_ref
           ),
         :ok <- RegistryExport.vacant(export.spec, worker.architecture, token) do
      :ok
    else
      {:error, error} -> {:error, %{error | evidence: :not_dispatched}}
      _invalid -> Session.error(:identity_conflict, :export)
    end
  end

  defp dispatch(config, machine, export) do
    with {:ok, intent} <- advance(config, machine, export, state: :dispatching),
         {:ok, worker} <- Machines.worker(config, intent) do
      pending = intent.exports[export.spec.id]

      # Only the operation itself can attest pre-dispatch rejection. A timeout,
      # lost task or store failure in the outer lease-renewal loop cannot tell
      # whether the HTTP request already reached the worker.
      response =
        Machines.io(config, intent, fn -> {:operation_result, publish(worker, intent, export)} end)

      case response do
        {:operation_result, result} -> received(config, intent, pending, worker, result)
        {:error, error} -> unknown(config, intent, pending, error)
        _lost -> unknown(config, intent, pending, %Error{category: :unknown, operation: :export})
      end
    end
  end

  defp publish(worker, machine, export) do
    with {:ok, token} <-
           RegistryCredentials.publication(
             worker.registry_credentials,
             export.spec.destination.credential_ref
           ),
         do: Client.export_machine(worker.client, machine.machine_name, export.spec, token)
  end

  defp received(config, machine, export, worker, {:ok, %ExportReceipt{} = receipt}) do
    expected = if worker.architecture == "x86_64", do: "linux/amd64", else: "linux/arm64"

    if receipt.platform == expected do
      with {:ok, saved} <- advance(config, machine, export, state: :verifying, receipt: receipt),
           do: verify(config, saved, saved.exports[export.spec.id])
    else
      unknown(config, machine, export, %Error{category: :protocol, operation: :export})
    end
  end

  defp received(config, machine, export, _worker, {:error, %{evidence: :not_dispatched} = error}),
    do: advance(config, machine, export, state: :failed, error: error)

  defp received(config, machine, export, _worker, {:error, error}),
    do: unknown(config, machine, export, error)

  defp received(config, machine, export, _worker, _invalid),
    do: unknown(config, machine, export, %Error{category: :protocol, operation: :export})

  defp verify(config, machine, export) do
    result =
      Machines.io(config, machine, fn ->
        with {:ok, worker} <- Machines.worker(config, machine),
             true <- approved?(worker, export.spec),
             {:ok, token} <-
               RegistryCredentials.publication(
                 worker.registry_credentials,
                 export.spec.destination.credential_ref
               ),
             do:
               RegistryExport.verify(
                 export.spec,
                 export.receipt,
                 token,
                 config.clock.now(),
                 worker.runtime_version
               ),
             else: (
               false -> Session.error(:unsupported_capability, :export)
               error -> error
             )
      end)

    case result do
      {:ok, verified} ->
        advance(config, machine, export, state: :published, result: verified)

      {:error, error} ->
        unknown(config, machine, export, error)

      _invalid ->
        unknown(config, machine, export, %Error{category: :protocol, operation: :export})
    end
  end

  defp unknown(config, machine, export, error),
    do: advance(config, machine, export, state: :unknown, error: %{error | evidence: :unknown})
end
