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
  alias SmolBox.Embedded.NativeBranchDeletion
  alias SmolBox.Runtime.NativeBranchDeletion, as: NativeBranchDeletionRuntime
  alias SmolBox.Runtime.NativeBranchDeletionAction

  alias SmolBox.Runtime.DiskExpansions
  alias SmolBox.Runtime.ExecutionSupport

  alias SmolBox.{
    Backend,
    Error,
    Execution,
    ExecutionSpec,
    ManagedMachine,
    ManagedMachineSpec,
    Runtime,
    Validation
  }

  alias SmolBox.Runtime.{Machines, NativeResolution, Session, Target, VolumeAccess}

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
    with :ok <- VolumeAccess.approved(config, spec, :new),
         do: accept_approved(config, spec, fingerprint)
  end

  defp accept_approved(config, spec, fingerprint) do
    if Enum.any?(config.workers, &Target.supports?(&1, spec)) do
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
         :ok <- Target.require_operation(worker, :logs),
         {:ok, observed} <-
           Backend.inspect_machine(Target.connection(worker, record), record.machine_name),
         true <- SmolBox.DiskExpansion.matches?(record, observed) do
      Backend.logs(Target.connection(worker, record), record.machine_name, options)
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
         :ok <- Target.require_operation(worker, :machine_measurements),
         {:ok, measured} <-
           Backend.machine_measurements(Target.connection(worker, record), record.machine_name),
         true <- SmolBox.DiskExpansion.matches?(record, measured.machine) do
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

  @doc """
  Accept durable disk growth on an idle stopped or created machine.

  Supply a unique operation `id`, the inspected machine `version`, and absolute
  `:storage_gb` and/or `:overlay_gb` targets (1–64 GiB). Identical retries return
  existing history, including after deletion. Conflicting reuse of an ID fails.
  Growth reserves capacity before dispatch and is blocked by durable draining.
  Requires smolvm 1.20.2 or 1.22.0 and `managed_disk_expansion: 1` store support.

  Creation identity stays immutable. Await with `await/3`, then inspect
  `record.disk_expansions[id]`. Unknown outcomes block reuse and retain capacity;
  resolve them explicitly with `resolve_disk_expansion/5`. Checkpointable,
  checkpoint-restored and branch machines are unsupported in this first version.
  """
  @spec expand_disks(SmolBox.runtime(), handle(), String.t(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def expand_disks(runtime, handle, id, version, options) do
    with :ok <- key(handle),
         {:ok, targets} <- SmolBox.DiskExpansion.targets(options),
         {:ok, config} <- config(runtime),
         :ok <- DiskExpansions.supported(config),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         {:ok, worker} <- Machines.worker(config, record),
         :ok <- Target.require_operation(worker, :expand_disks),
         true <- Target.supports_feature?(worker, :disk_growth) do
      Machines.store(config, :expansion_accept, [
        handle,
        id,
        version,
        targets,
        worker.capacity,
        config.clock.now()
      ])
    else
      false -> Session.error(:unsupported_capability, :expand_disks)
      error -> error
    end
  end

  @doc """
  Resolve an unknown expansion only after operator quiescence.

  Set `quiesced: true` after fencing old controllers and outstanding worker
  requests. For `disposition: :stopped` (default), first verify both actual disk
  files and worker metadata reached the complete target; partial growth or an old
  size observation is insufficient. This API verifies owned stopped target sizes.
  With `disposition: :deleted`, remove the resource after quiescence; verified
  absence releases accounting. Neither disposition resizes disks or updates SDK
  metadata. Embedded stopped resolution may qualify its saved geometry and publish
  an engine material proof after operator repair; it never replays the resize.
  """
  def resolve_disk_expansion(runtime, handle, id, version, options) do
    with true <-
           Validation.keys?(options, [:quiesced, :disposition]) and options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :stopped),
         true <- disposition in [:stopped, :deleted],
         :ok <- key(handle),
         {:ok, config} <- config(runtime),
         :ok <- DiskExpansions.supported(config),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         {:ok, worker} <- Machines.worker(config, record),
         :ok <- Target.require_operation(worker, :expand_disks) do
      NativeResolution.run(
        config,
        Runtime.coordinator(runtime),
        record,
        worker,
        disposition,
        fn pinned ->
          resolve_expansion(config, handle, id, version, pinned, disposition)
        end
      )
    else
      false -> Session.error(:validation, :expand_disks)
      error -> error
    end
  end

  defp resolve_expansion(config, handle, id, version, worker, disposition) do
    with {:ok, current} <-
           Machines.store(config, :claim_version, [
             handle,
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         true <- current.active_expansion == id and current.phase == :uncertain,
         result =
           Machines.io(config, %{current | operation_deadline_ms: nil}, fn ->
             DiskExpansions.resolution_observation(worker, current, disposition)
           end),
         {:ok, observed} <- resolution_observation(result, disposition) do
      DiskExpansions.advance(config, current, {:resolve, observed})
    else
      false -> Session.error(:validation, :expand_disks)
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
         do: submit_record(config, handle, record)
  end

  defp submit_record(config, handle, record) do
    # An accepted identity already owns its command slot. Repeating expensive
    # source qualification can compete with that very command's native budget.
    # Unknown/completed records are returned unchanged; no mutation is replayed.
    case Session.store(config, :fetch, [Execution.key(record)]) do
      {:ok, %Execution{fingerprint: fingerprint, managed_machine: machine} = existing}
      when fingerprint == record.fingerprint and machine == handle ->
        if Execution.validate(existing) == :ok,
          do: {:ok, Execution.key(existing)},
          else: Session.error(:store, :store)

      {:ok, %Execution{}} ->
        Session.error(:identity_conflict, :store)

      {:error, %Error{category: :not_found}} ->
        with :ok <- approved_command(config, handle, record.spec),
             {:ok, accepted} <-
               Machines.store(config, :submit, [
                 handle,
                 record,
                 config.max_pending,
                 config.clock.now()
               ]),
             do: {:ok, Execution.key(accepted)}

      {:error, %Error{}} = error ->
        error

      _ ->
        Session.error(:store, :store)
    end
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
         :ok <- Target.require_operation(worker, :list_images),
         {:ok, observed} <-
           Backend.inspect_machine(Target.connection(worker, record), record.machine_name),
         true <- SmolBox.DiskExpansion.matches?(record, observed) do
      Backend.list_images(Target.connection(worker, record), record.machine_name)
    else
      false -> Session.error(:identity_conflict, :images)
      error -> error
    end
  end

  defp approved_command(config, handle, spec) do
    with {:ok, record} <- Machines.store(config, :fetch, [handle]),
         {:ok, worker} <- Machines.worker(config, record),
         true <- command_approved?(worker, spec),
         :ok <- Target.qualify(Target.pin(worker), spec) do
      :ok
    else
      false -> Session.error(:unsupported_capability, command_operation(spec))
      error -> error
    end
  end

  defp command_approved?(%{kind: :embedded} = worker, spec), do: Target.supports?(worker, spec)

  defp command_approved?(worker, %{command: %SmolBox.ImagePull{}} = spec),
    do: Target.supports?(worker, spec)

  defp command_approved?(_worker, _spec), do: true

  defp command_operation(%{command: %SmolBox.ImagePull{}}), do: :pull_image
  defp command_operation(_spec), do: :submit

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
  Embedded resolution additionally freezes local target dispatch, drains pending
  requests and serializes against automatic reconciliation. It currently requires
  a saved full native receipt for stopped resolution. A lost receipt permits only
  deleted resolution after the original creation intent is verified absent.
  Present material remains unverified and reserved. Neither resolution nor
  subsequent reconciliation invents Exit or reclaims completed command history.

  An uncertain original native held-child delete uses its retained deletion
  context and a durably frozen request to confirm absence. The exact proof is
  retained with selective store codec v34. This releases only the child's ordinary
  reservation; source dependency and extra backing require separate branch APIs.
  It sends no SDK delete or filesystem cleanup. Remaining material cannot be
  resolved as absent, and a lost proof leaves the request and reservation intact
  for an explicit retry with the current management version.
  """
  def resolve(runtime, handle, version, options) do
    with true <-
           Validation.keys?(options, [:quiesced, :disposition]) and options[:quiesced] == true,
         disposition = Keyword.get(options, :disposition, :stopped),
         true <- disposition in [:stopped, :deleted],
         :ok <- key(handle),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         {:ok, worker} <- Machines.worker(config, record),
         :ok <- resolution_support(worker, record, disposition) do
      deadline =
        if disposition == :deleted and NativeBranchDeletion.required?(record),
          do:
            System.monotonic_time(:millisecond) +
              min(Target.connection(worker).budget.timeout_ms, 30_000)

      control = if deadline, do: {:ordinary_branch, :resolve_branch_deletion}, else: disposition

      NativeResolution.run(
        config,
        Runtime.coordinator(runtime),
        record,
        worker,
        control,
        fn pinned ->
          resolve_record(config, handle, version, pinned, disposition, deadline)
        end
      )
    else
      false -> Session.error(:validation, :reconcile)
      error -> error
    end
  end

  @doc """
  Collect the original child of an uncertain embedded branch-child deletion.

  Requires `quiesced: true`, the inspected management version and the retained
  original helper/completion/boot context. Acceptance freezes an independent
  request before helper IO; retries retain it. A matching saved acknowledgement
  returns without helper IO. This records historical collection only: deletion
  remains uncertain and every child/dependency/backing reservation stays charged.
  Use `continue_deletion/4` separately to finish an unentered final SDK deletion.
  An entered SDK deletion never replays. HTTP targets and restarted children do
  not support this operation. Native branch admission remains disabled pending
  ordinary qualification.
  """
  @spec collect_deletion(SmolBox.runtime(), handle(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def collect_deletion(runtime, handle, version, options),
    do: deletion_action(runtime, handle, version, options, :collect)

  @doc """
  Continue an uncertain original embedded branch-child deletion after quiescence.

  Requires `quiesced: true` and the inspected management version. The original
  helper must retain the returned delete worker, collected child and exact original
  completion, with the original release for a released child. Only the unfinished
  final SDK delete step may continue; an entered SDK delete never replays. Acceptance freezes the request before helper IO and
  retries retain it. A missing acknowledgement keeps the child reservation.
  A matching saved acknowledgement returns without helper IO. This releases only
  ordinary child capacity; source dependency and extra backing stay reserved.
  HTTP targets and restarted children do not support this operation. Public native
  branch admission remains disabled pending qualification.
  """
  @spec continue_deletion(SmolBox.runtime(), handle(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def continue_deletion(runtime, handle, version, options),
    do: deletion_action(runtime, handle, version, options, :continue)

  @doc """
  Remove residual files from an uncertain original embedded branch-child deletion.

  Requires `quiesced: true`, the inspected management version and the retained
  original helper context. Positive original-child collection and SDK row/reservation
  absence precede bounded removal through the pinned original directory authority.
  Held and initially/explicitly released children use distinct accepted grants.
  It sends no SDK shutdown/delete. Acceptance freezes a separate cleanup request;
  explicit retries retain it. Missing acknowledgement preserves the child slot.
  A matching saved acknowledgement returns without helper IO. Source dependencies
  and persistent backing require separate branch retirement/release APIs.
  HTTP targets and restarted children do not support this operation. Public native
  branch admission remains disabled pending qualification.
  """
  @spec cleanup_deletion(SmolBox.runtime(), handle(), pos_integer(), keyword()) ::
          {:ok, ManagedMachine.t()} | {:error, Error.t()}
  def cleanup_deletion(runtime, handle, version, options),
    do: deletion_action(runtime, handle, version, options, :cleanup)

  defp deletion_action(runtime, handle, version, options, action) do
    with true <- Validation.keys?(options, [:quiesced]) and options[:quiesced] == true,
         true <- Validation.integer?(version, 1, 9_007_199_254_740_991),
         :ok <- key(handle),
         {:ok, config} <- config(runtime),
         {:ok, record} <- Machines.store(config, :fetch, [handle]),
         do:
           NativeBranchDeletionAction.run(
             config,
             Runtime.coordinator(runtime),
             record,
             version,
             action
           ),
         else: (
           false -> Session.error(:validation, :reconcile)
           error -> error
         )
  end

  defp resolve_record(config, handle, version, worker, disposition, deadline) do
    with {:ok, current} <-
           Machines.store(config, :claim_version, [
             handle,
             version,
             config.owner,
             config.clock.now(),
             config.lease_ms
           ]),
         :ok <- Machines.port_support(config, current.spec.ports),
         do: resolve_current(config, current, worker, disposition, deadline)
  end

  defp resolution_support(worker, record, :deleted) do
    cond do
      not NativeBranchDeletion.required?(record) ->
        :ok

      NativeBranchDeletion.resolvable?(record) ->
        Target.require_operation(worker, :resolve_branch_deletion)

      true ->
        Session.error(:unsupported_capability, :reconcile)
    end
  end

  defp resolution_support(_, _, _), do: :ok

  defp resolve_current(config, current, worker, :deleted, deadline) do
    if NativeBranchDeletion.required?(current),
      do: NativeBranchDeletionRuntime.run(config, current, worker, deadline),
      else: resolve_observed(config, current, worker, :deleted)
  end

  defp resolve_current(config, current, worker, disposition, _deadline),
    do: resolve_observed(config, current, worker, disposition)

  defp resolve_observed(config, current, worker, disposition) do
    handle = ManagedMachine.key(current)

    observation =
      Machines.io(config, %{current | operation_deadline_ms: nil}, fn ->
        resolution_inspect(worker, current)
      end)

    with {:ok, observed} <- resolution_observation(observation, disposition),
         {:ok, fresh} <- Machines.claim(config, handle),
         do:
           Machines.store(config, :resolve, [
             handle,
             Session.guard(fresh),
             observed,
             config.clock.now()
           ])
  end

  defp resolution_inspect(%{kind: :embedded} = worker, %{created_machine: nil} = record),
    do: Backend.inspect_creation(resolution_reference(worker, record))

  defp resolution_inspect(worker, record),
    do: Backend.inspect_machine(resolution_reference(worker, record), record.machine_name)

  defp resolution_reference(%{kind: :embedded} = worker, record),
    do:
      worker
      |> Target.connection(record)
      |> Backend.bounded(timeout_ms: 1000, max_response_bytes: 16_384)

  defp resolution_reference(worker, record), do: Target.connection(worker, record)

  @doc "Schedule read-only recovery observation; this does not authorize replay of uncertain requests."
  def reconcile(runtime, handle) do
    with {:ok, record} <- __MODULE__.inspect(runtime, handle) do
      GenServer.call(Runtime.coordinator(runtime), {:reconcile, {:machine, handle}, record})
    end
  end

  defp resolution_observation({:ok, observed}, :stopped), do: {:ok, observed}

  defp resolution_observation({:ok, :absent}, :deleted), do: {:ok, :absent}

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
