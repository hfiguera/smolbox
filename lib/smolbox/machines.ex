defmodule SmolBox.Machines do
  @moduledoc """
  Managed machines retained until explicitly deleted.

  Create a `SmolBox.ManagedMachineSpec`, call `create/2`, inspect its record, then
  `start/3`. `submit/3` accepts an ordinary execution specification with the same
  scope, artifact, and profile. Commands share files but keep independent execution
  handles; use `SmolBox.await/3`, `SmolBox.fetch/3`, and `SmolBox.cancel/3` normally.

  Lifecycle requests take the inspected record version. Retrying the last identical
  request is idempotent. Superseded versions fail rather than reverse newer intent.
  Operations return accepted records; inspect until the intended state is observed.
  Stop and delete reject active commands, including unresolved unknown commands.
  All APIs require host authorization for the scope; handles are not credentials.
  """
  alias SmolBox.Runtime.ExecutionSupport

  alias SmolBox.{
    Error,
    Execution,
    ExecutionSpec,
    ManagedMachine,
    ManagedMachineSpec,
    Runtime,
    Validation
  }

  alias SmolBox.Runtime.{Machines, Session, WorkerConfig}

  @type handle :: ManagedMachine.key()

  @spec create(SmolBox.runtime(), ManagedMachineSpec.t()) :: {:ok, handle()} | {:error, Error.t()}
  def create(runtime, spec) do
    with {:ok, config} <- config(runtime),
         :ok <- ManagedMachineSpec.validate(spec),
         :ok <- ExecutionSupport.check(config, spec),
         :ok <- Machines.port_support(config, spec.ports),
         {:ok, fingerprint} <- ManagedMachineSpec.fingerprint(spec, config.fingerprint_key) do
      case Machines.store(config, :fetch, [{spec.scope, spec.id}]) do
        {:ok, %{fingerprint: ^fingerprint} = record} -> {:ok, ManagedMachine.key(record)}
        {:ok, _conflict} -> Session.error(:identity_conflict, :create)
        {:error, %Error{category: :not_found}} -> accept(config, spec, fingerprint)
        error -> error
      end
    end
  end

  defp accept(config, spec, fingerprint) do
    if Enum.any?(config.workers, &WorkerConfig.supports?(&1, spec)) do
      with {:ok, record} <- ManagedMachine.new(spec, fingerprint, config.clock.now()),
           {:ok, saved} <- Machines.store(config, :accept, [record, config.max_pending]),
           do: {:ok, ManagedMachine.key(saved)}
    else
      Session.error(:unsupported_capability, :create)
    end
  end

  @doc "Read durable management evidence without sending a worker request."
  def inspect(runtime, handle) do
    with :ok <- key(handle),
         {:ok, config} <- config(runtime),
         do: Machines.store(config, :fetch, [handle])
  end

  @doc """
  Read console diagnostics after verifying the recorded machine incarnation.

  Accepts `SmolBox.Client.logs/3` options. Log observation takes no command slot,
  persists no transcript, and never changes lifecycle intent or reservations.
  It may run alongside commands; stop/delete are not blocked by a log follower.
  Hosts must authorize scope access and protect log contents. Existing namespace
  exclusivity remains required throughout the observation.
  """
  @spec logs(SmolBox.runtime(), handle(), keyword()) ::
          {:ok, SmolBox.LogResult.t()} | {:error, Error.t()}
  def logs(runtime, handle, options \\ []) do
    with :ok <- key(handle),
         {:ok, _} <- SmolBox.LogOptions.validate(options),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         true <- record.state != :deleted and record.created_machine != nil,
         {:ok, worker} <- Machines.worker(config, record),
         {:ok, observed} <- SmolBox.Client.inspect_machine(worker.client, record.machine_name),
         true <- SmolBox.Machine.same_incarnation?(record.created_machine, observed) do
      SmolBox.Client.logs(worker.client, record.machine_name, options)
    else
      false -> Session.error(:identity_conflict, :logs)
      error -> error
    end
  end

  @doc """
  Read live measurements for a retained machine after checking recorded ownership.

  Takes no command slot and persists no measurements. May run during commands or
  while draining; it never starts/stops a guest, clears uncertainty or releases
  reservations. Hosts must authorize the handle's scope. Deletion or replacement
  can race any observation; this is evidence from one response, not a lifecycle lock.
  """
  @spec measurements(SmolBox.runtime(), handle()) ::
          {:ok, SmolBox.MachineMeasurements.t()} | {:error, Error.t()}
  def measurements(runtime, handle) do
    with :ok <- key(handle),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         true <- record.state != :deleted and record.created_machine != nil,
         {:ok, worker} <- Machines.worker(config, record),
         {:ok, measured} <-
           SmolBox.Client.machine_measurements(worker.client, record.machine_name),
         true <- SmolBox.Machine.same_incarnation?(record.created_machine, measured.machine) do
      {:ok, measured}
    else
      false -> Session.error(:identity_conflict, :machine_measurements)
      error -> error
    end
  end

  @doc """
  Wait for an idle lifecycle state or a blocked recovery state.

  Returns the stored record when no lifecycle operation or command remains active,
  or when its state is `:unknown`, `:missing`, or `:conflict`. Check the returned
  state. Timeout (0–900,000 ms) stops only this caller's wait, never the machine.
  This is also useful after `SmolBox.await/3`, whose result can precede release of
  the machine's command slot.
  """
  @spec await(SmolBox.runtime(), handle(), non_neg_integer()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def await(runtime, handle, timeout) do
    if Validation.integer?(timeout, 0, 900_000),
      do: await_until(runtime, handle, System.monotonic_time(:millisecond) + timeout),
      else: Session.error(:validation, :machine)
  end

  defp await_until(runtime, handle, deadline) do
    with {:ok, machine} <- __MODULE__.inspect(runtime, handle) do
      cond do
        ManagedMachine.idle?(machine) or machine.state in [:unknown, :missing, :conflict] ->
          {:ok, machine}

        System.monotonic_time(:millisecond) >= deadline ->
          Session.error(:expired, :machine)

        true ->
          receive do
          after
            25 -> await_until(runtime, handle, deadline)
          end
      end
    end
  end

  @doc "Read a scoped page, including deleted identities; cursor is the previous page's final ID."
  def list(runtime, scope, options \\ []) do
    with true <- Validation.keys?(options, [:cursor, :limit]),
         {:ok, config} <- config(runtime) do
      Machines.store(config, :list, [
        scope,
        Keyword.get(options, :cursor),
        Keyword.get(options, :limit, 20)
      ])
    else
      false -> Session.error(:validation, :list)
      error -> error
    end
  end

  @doc "Persist start intent against an inspected record version."
  def start(runtime, handle, version), do: request(runtime, handle, :start, version)
  @doc "Persist stop intent, preserving disks and the complete capacity reservation."
  def stop(runtime, handle, version), do: request(runtime, handle, :stop, version)
  @doc "Persist explicit disposal intent; completion requires verified absence."
  def delete(runtime, handle, version), do: request(runtime, handle, :delete, version)

  defp request(runtime, handle, action, version) do
    with :ok <- key(handle),
         {:ok, config} <- config(runtime),
         :ok <- supported_machine(config, handle),
         do: Machines.store(config, :request, [handle, action, version, config.clock.now()])
  end

  defp supported_machine(config, handle) do
    with {:ok, machine} <- Machines.store(config, :fetch, [handle]),
         :ok <- Machines.port_support(config, machine.spec.ports),
         do: ExecutionSupport.check(config, machine.spec)
  end

  @doc "Accept one command on an idle running machine; identical duplicates return the original execution."
  def submit(runtime, handle, spec) do
    with :ok <- key(handle),
         {:ok, config} <- config(runtime),
         :ok <- ExecutionSpec.validate(spec),
         :ok <- ExecutionSupport.check(config, spec),
         :ok <- supported_machine(config, handle),
         :ok <- approved_pull(config, handle, spec),
         {:ok, fingerprint} <- ExecutionSpec.fingerprint(spec, config.fingerprint_key),
         digest =
           :crypto.mac(
             :hmac,
             :sha256,
             config.fingerprint_key,
             :erlang.term_to_binary({"smolbox-machine-command-v1", handle, fingerprint})
           )
           |> Base.encode16(case: :lower),
         {:ok, record} <- Execution.new(spec, digest, config.clock.now()),
         {:ok, accepted} <-
           Machines.store(config, :submit, [
             handle,
             record,
             config.max_pending,
             config.clock.now()
           ]),
         do: {:ok, Execution.key(accepted)}
  end

  @doc """
  Submit a durable OCI pull on an idle, running retained machine.

  `id` identifies this operation within the machine's scope. Identical retries
  return its original execution handle; different intent with the same ID is an
  identity conflict. Options are `:queue_ms`, `:retention_ms`, and `:metadata` as
  in `SmolBox.ExecutionSpec`. The machine's execution budget bounds observation.
  Use `SmolBox.await/3` to obtain `:completed`, `:image_pulled` evidence and a typed
  `SmolBox.Image` result. Wait for `await/3` before submitting the next operation.

  The source must be an exact OCI approval on the assigned worker. The machine
  must originate from OCI and have an explicit network profile. Prepared artifacts
  and checkpoints cannot support verified pulls upstream. Pulling uses the same slot as
  commands, terminal sessions and their file transfers; stop/delete reject it.
  It never changes the machine's creation source or runs a workload. Cancellation
  after dispatch or a lost response leaves an unknown outcome and blocks reuse
  until operator quiescence and `resolve/4`. Listing images cannot resolve it.
  """
  @spec pull_image(SmolBox.runtime(), handle(), String.t(), SmolBox.Source.t(), keyword()) ::
          {:ok, SmolBox.handle()} | {:error, Error.t()}
  def pull_image(runtime, handle, id, source, options \\ []) do
    with true <- Validation.keys?(options, [:queue_ms, :retention_ms, :metadata]),
         {:ok, machine} <- __MODULE__.inspect(runtime, handle),
         :ok <- pull_machine(machine),
         {:ok, pull} <- SmolBox.ImagePull.new(source),
         {:ok, spec} <-
           ExecutionSpec.new(
             [
               scope: machine.scope,
               id: id,
               artifact: machine.spec.artifact,
               profile: machine.spec.profile,
               command: pull
             ] ++ options
           ) do
      submit(runtime, handle, spec)
    else
      false -> Session.error(:validation, :pull_image)
      error -> error
    end
  end

  @doc """
  Observe machine-local images after verifying the recorded incarnation.

  This passive read takes no active-operation slot and never starts a machine.
  Empty inventories remain `:empty_or_unavailable`, including stopped machines.
  A concurrent pull may still be in progress; listing is not completion evidence.
  Namespace exclusivity remains required, as with `logs/3`.
  """
  @spec list_images(SmolBox.runtime(), handle()) ::
          {:ok, SmolBox.ImageInventory.t()} | {:error, Error.t()}
  def list_images(runtime, handle) do
    with :ok <- key(handle),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         true <- record.state != :deleted and record.created_machine != nil,
         {:ok, worker} <- Machines.worker(config, record),
         {:ok, observed} <- SmolBox.Client.inspect_machine(worker.client, record.machine_name),
         true <- SmolBox.Machine.same_incarnation?(record.created_machine, observed) do
      SmolBox.Client.list_images(worker.client, record.machine_name)
    else
      false -> Session.error(:identity_conflict, :images)
      error -> error
    end
  end

  defp approved_pull(config, handle, %{command: %SmolBox.ImagePull{}} = spec) do
    with {:ok, record} <- Machines.store(config, :fetch, [handle]),
         {:ok, worker} <- Machines.worker(config, record),
         true <- WorkerConfig.supports?(worker, spec) do
      :ok
    else
      false -> Session.error(:unsupported_capability, :pull_image)
      error -> error
    end
  end

  defp approved_pull(_config, _handle, _spec), do: :ok

  defp pull_machine(%{spec: %{artifact: %{"kind" => "oci"}}}), do: :ok
  defp pull_machine(_machine), do: Session.error(:unsupported_capability, :pull_image)

  @doc """
  Resolve blocked reuse after operator quiescence, preserving unknown outcomes.

  Before calling with `quiesced: true`, the operator must terminate old controllers
  and drain/fence their outstanding worker requests, then stop the verified machine.
  A stopped observation alone is insufficient. This API verifies the recorded owned
  incarnation is stopped; it never adopts an unverified creation or replays a command.
  The expected version prevents resolution against a different management record.
  With `disposition: :deleted`, the operator instead removes the resource after
  quiescence. This call verifies absence and releases capacity; it sends no delete.
  This also resolves a lost creation response without adopting an unverified VM.
  """
  def resolve(runtime, handle, version, options) do
    with true <-
           Validation.keys?(options, [:quiesced, :disposition]) and options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :stopped),
         true <- disposition in [:stopped, :deleted],
         :ok <- key(handle),
         {:ok, config} <- config(runtime),
         {:ok, current} <-
           Machines.store(config, :claim_version, [
             handle,
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         :ok <- Machines.port_support(config, current.spec.ports),
         {:ok, worker} <- Machines.worker(config, current),
         observation =
           Machines.io(config, %{current | operation_deadline_ms: nil}, fn ->
             SmolBox.Client.inspect_machine(worker.client, current.machine_name)
           end),
         {:ok, observed} <- resolution_observation(observation, disposition),
         {:ok, fresh} <- Machines.claim(config, handle) do
      Machines.store(config, :resolve, [
        handle,
        Session.guard(fresh),
        observed,
        config.clock.now()
      ])
    else
      false -> Session.error(:validation, :reconcile)
      error -> error
    end
  end

  @doc "Schedule read-only recovery observation; this does not authorize replay of uncertain requests."
  def reconcile(runtime, handle) do
    with {:ok, _record} <- __MODULE__.inspect(runtime, handle) do
      GenServer.call(Runtime.coordinator(runtime), {:reconcile, {:machine, handle}})
    end
  end

  defp resolution_observation({:ok, observed}, :stopped), do: {:ok, observed}

  defp resolution_observation({:error, %Error{category: :not_found}}, :deleted),
    do: {:ok, :absent}

  defp resolution_observation({:error, _error} = error, _disposition), do: error

  defp resolution_observation(_observation, _disposition),
    do: Session.error(:identity_conflict, :reconcile)

  defp config(runtime) do
    with {:ok, config} <- GenServer.call(Runtime.coordinator(runtime), :config),
         true <- config.managed_machines do
      {:ok, config}
    else
      false -> Session.error(:unsupported_capability, :machine)
      error -> error
    end
  rescue
    _redacted -> Session.error(:unknown, :runtime)
  catch
    :exit, _redacted -> Session.error(:unknown, :runtime)
  end

  defp key({scope, id}) do
    if Validation.identifier?(scope) and Validation.identifier?(id),
      do: :ok,
      else: Session.error(:validation, :machine)
  end

  defp key(_handle), do: Session.error(:validation, :machine)
end
