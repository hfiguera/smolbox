defmodule SmolBox.Exports do
  @moduledoc """
  Managed stopped-machine exports with durable intent and explicit recovery.

  Submit an approved `SmolBox.ExportSpec` against a stopped retained machine.
  Exports share its exclusive operation slot but never become command executions.
  Completed history survives machine deletion. Hosts authorize every scope and
  configure exact destinations on the owning worker. Handles are not credentials.
  """
  alias SmolBox.{Client, Error, Export, ExportSpec, ManagedMachine, Runtime, Validation}
  alias SmolBox.Runtime.Exports, as: ExportRuntime
  alias SmolBox.Runtime.{Machines, Session}

  @spec submit(SmolBox.runtime(), ManagedMachine.key(), ExportSpec.t()) ::
          {:ok, Export.handle()} | {:error, Error.t()}
  def submit(runtime, machine, spec) do
    with :ok <- ExportSpec.validate(spec),
         {:ok, config} <- configuration(runtime),
         {:ok, record} <- SmolBox.Machines.inspect(runtime, machine),
         {:ok, fingerprint} <- ExportSpec.fingerprint(spec, machine, config.fingerprint_key) do
      case record.exports[spec.id] do
        %Export{fingerprint: ^fingerprint} -> handle(record, spec)
        %Export{} -> Session.error(:identity_conflict, :export)
        nil -> accept(config, record, spec, fingerprint)
      end
    end
  end

  defp accept(config, record, spec, fingerprint) do
    with {:ok, worker} <- Machines.worker(config, record),
         true <- ExportRuntime.approved?(worker, spec),
         {:ok, saved} <-
           Machines.store(config, :export_accept, [
             ManagedMachine.key(record),
             spec,
             fingerprint,
             worker.capacity,
             config.clock.now()
           ]) do
      handle(saved, spec)
    else
      false -> Session.error(:unsupported_capability, :export)
      error -> error
    end
  end

  @doc "Read durable export evidence; makes no worker or registry request."
  @spec fetch(SmolBox.runtime(), Export.handle()) :: {:ok, Export.t()} | {:error, Error.t()}
  def fetch(runtime, {scope, machine, id}) do
    with true <- Validation.identifier?(id),
         {:ok, record} <- SmolBox.Machines.inspect(runtime, {scope, machine}) do
      case record.exports[id] do
        %Export{} = export -> {:ok, export}
        nil -> Session.error(:not_found, :export)
      end
    else
      false -> Session.error(:validation, :export)
      error -> error
    end
  end

  def fetch(_runtime, _handle), do: Session.error(:validation, :export)

  @doc "Wait for a terminal, unknown or published outcome. Timeout stops only this wait."
  @spec await(SmolBox.runtime(), Export.handle(), non_neg_integer()) ::
          {:ok, Export.t()} | {:error, Error.t()}
  def await(runtime, handle, timeout_ms) do
    if Validation.integer?(timeout_ms, 0, 900_000),
      do: wait(runtime, handle, System.monotonic_time(:millisecond) + timeout_ms),
      else: Session.error(:validation, :export)
  end

  defp wait(runtime, handle, deadline) do
    with {:ok, record} <- fetch(runtime, handle) do
      cond do
        Export.terminal?(record) or record.state in [:unknown, :published] ->
          {:ok, record}

        System.monotonic_time(:millisecond) >= deadline ->
          Session.error(:expired, :export)

        true ->
          receive do
          after
            25 -> wait(runtime, handle, deadline)
          end
      end
    end
  end

  @doc """
  Cancel accepted work. During dispatch or verification, retain an unknown
  outcome and its reservations. Published and terminal records are unchanged;
  cancellation never revokes publication or confirms helper cleanup.
  """
  @spec cancel(SmolBox.runtime(), Export.handle()) :: {:ok, Export.t()} | {:error, Error.t()}
  def cancel(runtime, {scope, machine, id} = handle) do
    with {:ok, _record} <- fetch(runtime, handle),
         {:ok, config} <- configuration(runtime),
         {:ok, saved} <-
           Machines.store(config, :export_cancel, [{scope, machine}, id, config.clock.now()]),
         do: {:ok, saved.exports[id]}
  end

  def cancel(_runtime, _handle), do: Session.error(:validation, :export)

  @doc """
  Resolve an unknown export or confirm cleanup after verified publication.

  A `:published` export becomes `:completed`, retaining its verified result.
  The successful HTTP response does not attest that its helper terminated:
  verify helper processes and staging cleanup separately before confirmation.

  Requires `[quiesced: true]` and the current machine version. Stop/restart of
  the controller, an expired lease or a stopped observation is insufficient:
  the operator must fence pending worker requests and stop/reap export helper
  subprocesses and publication before calling. Registry publication may still
  have succeeded; `:resolved_unknown` preserves that uncertainty and permanently
  retains destination claims. With `disposition: :deleted`, verify absence after
  the operator has removed the quiescent source, preserving its tombstone while
  releasing its reservation. This never deletes registry objects or replays.
  """
  @spec resolve(SmolBox.runtime(), Export.handle(), pos_integer(), keyword()) ::
          {:ok, Export.t()} | {:error, Error.t()}
  def resolve(runtime, {scope, machine, id} = handle, version, options) do
    with true <-
           Validation.keys?(options, [:quiesced, :disposition]) and options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :stopped),
         true <- disposition in [:stopped, :deleted],
         {:ok, %{state: state}} <- fetch(runtime, handle),
         true <- state in [:unknown, :published],
         {:ok, config} <- configuration(runtime),
         {:ok, record} <-
           Machines.store(config, :claim_version, [
             {scope, machine},
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         {:ok, worker} <- Machines.worker(config, record),
         {:ok, observed} <-
           Machines.io(config, %{record | operation_deadline_ms: nil}, fn ->
             observe_resolution(worker.client, record.machine_name, disposition)
           end),
         {:ok, current} <- Machines.claim(config, {scope, machine}),
         {:ok, saved} <-
           Machines.store(config, :export_resolve, [
             {scope, machine},
             Session.guard(current),
             id,
             observed,
             config.clock.now()
           ]),
         do: {:ok, saved.exports[id]},
         else: (
           false -> Session.error(:validation, :export)
           error -> error
         )
  end

  def resolve(_runtime, _handle, _version, _options), do: Session.error(:validation, :export)

  defp observe_resolution(client, name, disposition) do
    case {Client.inspect_machine(client, name), disposition} do
      {{:ok, observed}, :stopped} -> {:ok, observed}
      {{:error, %Error{category: :not_found}}, :deleted} -> {:ok, :absent}
      {{:error, _error} = error, _disposition} -> error
      _conflict -> Session.error(:identity_conflict, :export)
    end
  end

  defp configuration(runtime) do
    with {:ok, config} <- GenServer.call(Runtime.coordinator(runtime), :config),
         true <- config.managed_machines,
         {:ok, %{managed_exports: 1}} <- Session.store(config, :capabilities, []) do
      {:ok, config}
    else
      {:error, _error} = error -> error
      _unsupported -> Session.error(:unsupported_capability, :export)
    end
  rescue
    _redacted -> Session.error(:unknown, :runtime)
  catch
    :exit, _redacted -> Session.error(:unknown, :runtime)
  end

  defp handle(machine, spec), do: {:ok, {machine.scope, machine.id, spec.id}}
end
