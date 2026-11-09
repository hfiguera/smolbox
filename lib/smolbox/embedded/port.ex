defmodule SmolBox.Embedded.Port do
  @moduledoc false
  use GenServer
  @behaviour SmolBox.Embedded.Bridge
  alias SmolBox.Backend.{Budget, Features}

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchChildAbsence,
    BranchDeletionCollection,
    BranchDeletionResolution,
    BranchRequest,
    Channel,
    CheckpointContract,
    CommandPayload,
    Config,
    CreationFeatures,
    CreationPayload,
    ExportContract,
    Frame,
    HeldBranchDeletionAction,
    HeldBranchReleaseRequest,
    ImageContract,
    JSON,
    Launch,
    MountContract,
    NativeSource,
    Outbox,
    PartialBranchBackingRelease,
    PartialBranchChildAbsence,
    PartialBranchCollection,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PreparedBranchRetirement,
    Protocol,
    RegistryContract,
    ReleasedBranchDeletionCleanup,
    ReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionResolution,
    Request,
    Shape,
    TerminalContract,
    UnbootedBranchBackingRelease,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal,
    VolumeContract
  }

  alias SmolBox.{Error, Source, Validation}

  @impl true
  def start_link(config, options \\ []) do
    with :ok <- Config.validate(config),
         true <- Validation.keys?(options, [:name]) do
      GenServer.start_link(__MODULE__, config, options)
    else
      _invalid -> failure(:validation)
    end
  end

  @impl true
  def submit(server, request, budget, observer) do
    if Budget.valid?(budget) and request_shape?(request, budget.timeout_ms) and is_pid(observer),
      do: call(server, {:submit, request, budget, observer, now() + budget.timeout_ms}),
      else: failure(:validation)
  end

  @impl true
  def submit(server, request, budget, observer, epoch) do
    if Budget.valid?(budget) and request_shape?(request, budget.timeout_ms) and is_pid(observer) and
         Shape.hex?(epoch, 32),
       do: call(server, {:submit, request, budget, observer, now() + budget.timeout_ms, epoch}),
       else: failure(:validation)
  end

  @impl true
  def acknowledge(server, handle, bytes), do: call(server, {:acknowledge, handle, bytes})
  @impl true
  def cancel(server, handle), do: call(server, {:cancel, handle})
  @impl true
  def upload(server, handle, bytes)
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= 65_536,
      do: call(server, {:upload, handle, bytes})

  def upload(_server, _handle, _bytes), do: failure(:validation)
  @impl true
  def terminal_control(server, handle, control) do
    if TerminalContract.action?(control),
      do: call(server, {:terminal_control, handle, control}),
      else: failure(:validation)
  end

  @impl true
  def activate(server, binding), do: call(server, {:activate, binding})
  @impl true
  def activate(server, binding, epoch), do: activate(server, binding, epoch, 15_000)

  @impl true
  def activate(server, binding, epoch, timeout) do
    if Shape.hex?(epoch, 32),
      do: call(server, {:activate, binding, epoch}, timeout),
      else: failure(:validation)
  end

  @impl true
  def quiesce(server, epoch), do: quiesce(server, epoch, 15_000)

  @impl true
  def quiesce(server, epoch, timeout) do
    if Shape.hex?(epoch, 32),
      do: call(server, {:quiesce, epoch}, timeout),
      else: failure(:validation)
  end

  @impl true
  def shutdown(server), do: call(server, :shutdown)
  @impl true
  def health(server), do: call(server, :health)

  @impl true
  def health(server, timeout), do: call(server, :health, timeout)
  @impl true
  def export_approval(server, id, epoch, timeout) do
    if Shape.id?(id) and Shape.hex?(epoch, 32) and Validation.integer?(timeout, 1, 30_000),
      do: call(server, {:export_approval, id, epoch}, timeout),
      else: failure(:validation)
  end

  @impl true
  def submit(server, request, budget, observer, epoch, timeout) do
    if Budget.valid?(budget) and request_shape?(request, budget.timeout_ms) and is_pid(observer) and
         Shape.hex?(epoch, 32),
       do:
         call(
           server,
           {:submit, request, budget, observer, now() + budget.timeout_ms, epoch},
           timeout
         ),
       else: failure(:validation)
  end

  @impl true
  def terminal_control(server, handle, control, timeout) do
    if TerminalContract.action?(control),
      do: call(server, {:terminal_control, handle, control}, timeout),
      else: failure(:validation)
  end

  @impl true
  def acknowledge(server, handle, bytes, timeout),
    do: call(server, {:acknowledge, handle, bytes}, timeout)

  @impl true
  def cancel(server, handle, timeout), do: call(server, {:cancel, handle}, timeout)

  # The caller does not choose the protocol. This only bounds input before the
  # GenServer call; Channel.register enforces the approved session's exact major.
  defp request_shape?(request, budget),
    do: Request.valid?(request, budget, 1) or Request.valid?(request, budget, 2)

  defp call(server, request, timeout \\ 15_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _redacted -> failure(:unknown, :dispatch_uncertain)
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    if :global.register_name({__MODULE__, node()}, self()) == :yes do
      state = %{
        config: config,
        status: :starting,
        port: nil,
        preparing: nil,
        directory: nil,
        cleanup_watcher: Launch.watch(self()),
        export_approvals: [],
        frame: %Frame{},
        channel: nil,
        protocol_major: Config.protocol_major(config),
        protocol_minor: nil,
        records: %{},
        handles: %{},
        monitors: %{},
        outbox: %Outbox{},
        upload_reserved: 0,
        startup_token: nil,
        startup_timer: nil,
        flush_timer: nil,
        restart_timer: nil,
        backoff_ms: 1000,
        shutdown_token: nil,
        shutdown_timer: nil,
        shutting_down: false,
        closing: false
      }

      send(self(), :open)
      {:ok, state}
    else
      {:stop, %Error{category: :identity_conflict, operation: :embedded}}
    end
  end

  @impl true
  def handle_call(:health, _from, state),
    do:
      {:reply,
       {:ok,
        %{
          status: state.status,
          target_id: state.config.id,
          generation: state.config.domain_generation,
          package_identity: state.config.package_identity,
          package_manifest_sha256: state.config.package_manifest_sha256,
          protocol_minor: if(state.channel, do: state.channel.minor),
          protocol_major: if(state.channel, do: state.channel.major),
          epoch: if(state.channel, do: state.channel.epoch)
        }}, state}

  def handle_call({:export_approval, id, epoch}, _from, state) do
    with true <- state.status == :ready and state.channel != nil and state.channel.epoch == epoch,
         true <- Features.supports?(state.config, :exports),
         approval when not is_nil(approval) <-
           Enum.find(state.export_approvals, &(&1["id"] == id)) do
      {:reply,
       {:ok,
        Map.take(
          approval,
          ~w(id destination_sha256 max_artifact_bytes max_staging_bytes conversion_resources)
        )}, state}
    else
      _ -> {:reply, failure(:unsupported_capability), state}
    end
  end

  def handle_call({:activate, binding}, _from, %{status: :reconciling} = state) do
    if binding == Config.domain_binding(state.config),
      do: {:reply, :ok, %{state | status: :ready, backoff_ms: 1000}},
      else: {:reply, failure(:identity_conflict), state}
  end

  def handle_call({:activate, binding}, _from, %{status: :ready} = state) do
    if binding == Config.domain_binding(state.config),
      do: {:reply, :ok, state},
      else: {:reply, failure(:identity_conflict), state}
  end

  def handle_call({:activate, binding, epoch}, from, state) do
    cond do
      is_nil(state.channel) or state.channel.epoch != epoch ->
        {:reply, failure(:identity_conflict), state}

      map_size(state.records) != 0 ->
        {:reply, failure(:admission_exhausted), state}

      true ->
        handle_call({:activate, binding}, from, state)
    end
  end

  def handle_call({:quiesce, epoch}, _from, state) do
    if (state.channel && state.channel.epoch == epoch) and
         (state.status in [:ready, :reconciling] or
            (state.status == :quarantined and state.channel.major == 2)) do
      state = if state.status == :quarantined, do: state, else: %{state | status: :reconciling}
      result = if map_size(state.records) == 0, do: :ok, else: failure(:admission_exhausted)
      {:reply, result, state}
    else
      {:reply, failure(:identity_conflict), state}
    end
  end

  def handle_call({:submit, operation, budget, observer, deadline, epoch}, from, state) do
    if state.channel && state.channel.epoch == epoch,
      do: handle_call({:submit, operation, budget, observer, deadline}, from, state),
      else: {:reply, failure(:identity_conflict), state}
  end

  def handle_call({:submit, operation, budget, observer, deadline}, {caller, _tag}, state) do
    case admit(state, operation, budget, observer, caller, deadline) do
      {:ok, handle, state} -> {:reply, {:ok, handle}, schedule_flush(state)}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:acknowledge, handle, bytes}, {caller, _tag}, state) do
    with {:ok, id, record} <- lookup(state, handle),
         true <- record.observer == caller,
         true <- Validation.integer?(bytes, 1, record.owed),
         {:ok, state} <- consume(state, id, bytes) do
      {:reply, :ok, schedule_flush(retire_if_consumed(state, id))}
    else
      _invalid -> {:reply, failure(:validation), state}
    end
  end

  def handle_call({:cancel, handle}, {caller, _tag}, state) do
    case lookup(state, handle) do
      {:ok, id, record} when caller == record.caller or caller == record.observer ->
        {:reply, :ok, schedule_flush(cancel_request(state, id, :unknown))}

      _invalid ->
        {:reply, failure(:validation), state}
    end
  end

  def handle_call({:upload, handle, bytes}, {caller, _tag}, state) do
    with {:ok, id, record} <- lookup(state, handle),
         true <- caller == record.caller and not record.notified and record.error == nil,
         %{"operation" => "write_file", "total_bytes" => total} <- record.operation,
         true <- record.upload_planned + byte_size(bytes) <= total,
         message = %{
           "type" => "upload",
           "epoch" => state.channel.epoch,
           "id" => id,
           "offset" => record.upload_planned,
           "data_base64" => Base.encode64(bytes)
         },
         {:ok, outbox} <-
           Outbox.put(
             state.outbox,
             %{kind: :upload, id: id, message: message, decoded_bytes: byte_size(bytes)},
             state.config.limits.send_queue_bytes
           ) do
      record = %{record | upload_planned: record.upload_planned + byte_size(bytes)}

      {:reply, :ok,
       schedule_flush(%{state | outbox: outbox, records: Map.put(state.records, id, record)})}
    else
      _invalid -> {:reply, failure(:admission_exhausted), state}
    end
  end

  def handle_call({:terminal_control, handle, control}, {caller, _tag}, state) do
    with {:ok, id, record} <- lookup(state, handle),
         true <- caller == record.observer and not record.notified and record.error == nil,
         true <- not state.closing,
         true <- now() < record.deadline,
         %{"operation" => "terminal_open"} <- record.operation,
         sequence = state.channel.pending[id].terminal_control + 1,
         {:ok, channel, true} <- Channel.terminal_control(state.channel, id, sequence, control),
         message = %{
           "type" => "terminal_control",
           "epoch" => channel.epoch,
           "id" => id,
           "sequence" => sequence,
           "control" => control
         },
         {:ok, outbox} <-
           Outbox.put(
             state.outbox,
             %{kind: :terminal_control, id: id, message: message},
             state.config.limits.send_queue_bytes
           ) do
      {:reply, :ok, schedule_flush(%{state | channel: channel, outbox: outbox})}
    else
      _invalid -> {:reply, failure(:admission_exhausted), state}
    end
  end

  def handle_call(:shutdown, _from, state) do
    state = %{state | shutting_down: true, status: :closing}
    state = close_channel(state, :unknown)
    {:reply, :ok, begin_close(state)}
  end

  def handle_call(_request, _from, state), do: {:reply, failure(:validation), state}

  @impl true
  def handle_info(:open, %{port: nil, preparing: nil, shutting_down: false} = state) do
    state = %{state | restart_timer: nil}
    if map_size(state.records) == 0, do: open(state), else: {:noreply, restart_later(state)}
  end

  def handle_info(:open, state), do: {:noreply, %{state | restart_timer: nil}}

  def handle_info({:prepared, token, result}, %{startup_token: token} = state) do
    state = %{state | preparing: nil}

    case result do
      {:ok, prepared} ->
        case Launch.open(prepared) do
          {:ok, port} ->
            {:noreply,
             %{
               state
               | port: port,
                 export_approvals: prepared.export_approvals,
                 protocol_major: prepared.protocol_major,
                 protocol_minor: prepared.protocol_minor,
                 status: :handshaking
             }}

          _failed ->
            {:noreply, failed_start(state)}
        end

      _failed ->
        {:noreply, failed_start(state)}
    end
  end

  def handle_info({:prepared, _token, _result}, state), do: {:noreply, state}

  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case Frame.push(state.frame, bytes) do
      {:ok, frame, bodies} ->
        state = %{state | frame: frame}

        state = Enum.reduce_while(bodies, state, &receive_next/2)

        {:noreply, schedule_flush(state)}

      :error ->
        {:noreply, protocol_failure(state)}
    end
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state),
    do: {:noreply, port_exited(state)}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) when is_port(port),
    do: {:noreply, begin_close(close_channel(state, :transport))}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil -> {:noreply, state}
      id -> {:noreply, schedule_flush(observer_down(state, id, ref))}
    end
  end

  def handle_info({:EXIT, pid, :normal}, %{preparing: pid} = state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %{preparing: pid} = state),
    do: {:noreply, failed_start(%{state | preparing: nil})}

  def handle_info({:startup_timeout, token}, %{startup_token: token} = state) do
    state = %{state | startup_token: nil}

    if state.preparing do
      Process.exit(state.preparing, :kill)
      {:noreply, failed_start(%{state | preparing: nil})}
    else
      {:noreply, begin_close(close_channel(state, :expired))}
    end
  end

  def handle_info({:deadline, id, handle}, state) do
    case Map.get(state.records, id) do
      %{handle: ^handle, notified: false} ->
        {:noreply, schedule_flush(cancel_request(state, id, :expired))}

      _finished ->
        {:noreply, state}
    end
  end

  def handle_info({:cancel_timeout, id, handle}, state) do
    case Map.get(state.records, id) do
      %{handle: ^handle, notified: false} ->
        {:noreply, begin_close(close_channel(state, :unknown))}

      _finished ->
        {:noreply, state}
    end
  end

  def handle_info({:close_timeout, token}, %{shutdown_token: token} = state) do
    close_port(state.port)
    # No exit_status was observed: do not spawn another helper on this authority.
    {:noreply, %{state | port: nil, status: :quarantined, shutdown_token: nil, closing: false}}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil}, 0)}
  def handle_info(_ignored, state), do: {:noreply, state}

  defp admit(state, operation, budget, observer, caller, deadline) do
    remaining = min(deadline - now(), min(budget.timeout_ms, state.config.budget.timeout_ms))

    cond do
      not admission_status?(state, operation) ->
        failure(:transport)

      state.status == :reconciling and
          not Request.reconciliation?(operation) ->
        failure(:transport)

      remaining <= 0 ->
        failure(:expired)

      map_size(state.records) >= state.config.limits.in_flight ->
        failure(:admission_exhausted)

      not operation_available?(state, operation) ->
        failure(:unsupported_capability)

      state.upload_reserved + Map.get(operation, "total_bytes", 0) >
          state.config.limits.upload_bytes ->
        failure(:admission_exhausted)

      true ->
        register(state, operation, budget, observer, caller, remaining)
    end
  end

  defp operation_available?(state, operation),
    do:
      approved?(state.config, operation) and
        ExportContract.approved_cached?(state.export_approvals, operation)

  defp admission_status?(state, operation),
    do: state.status in [:ready, :reconciling] or quarantined_control?(state, operation)

  defp quarantined_control?(state, operation),
    do:
      state.status == :quarantined and is_port(state.port) and not state.closing and
        not state.shutting_down and state.channel != nil and state.channel.major == 2 and
        state.channel.unavailable and Request.control?(operation)

  defp register(state, operation, budget, observer, caller, remaining) do
    limits = state.config.limits

    credit_bytes =
      if operation["operation"] == "terminal_open",
        do: min(limits.initial_credit_bytes, operation["terminal"]["max_buffer_bytes"]),
        else: limits.initial_credit_bytes

    with {:ok, id, channel} <-
           Channel.register(
             state.channel,
             operation,
             credit_bytes,
             limits.initial_credit_events
           ),
         message = %{
           "type" => "request",
           "epoch" => channel.epoch,
           "id" => id,
           "budget_ms" => remaining,
           "initial_credit" => credit_bytes,
           "initial_event_credit" => limits.initial_credit_events,
           "operation" => operation
         },
         {:ok, wire_operation} <- CreationPayload.pack(operation, state.config),
         message = %{message | "operation" => wire_operation},
         {:ok, wire_operation} <- CommandPayload.pack(wire_operation),
         message = %{message | "operation" => wire_operation},
         {:ok, outbox} <-
           Outbox.put(
             state.outbox,
             %{kind: :request, id: id, message: message},
             limits.send_queue_bytes
           ),
         true <-
           byte_size(List.last(:queue.to_list(outbox.data)).encoded) - 4 <=
             min(budget.max_request_bytes, state.config.budget.max_request_bytes) do
      handle = make_ref()
      refs = Enum.uniq([caller, observer]) |> Map.new(&{Process.monitor(&1), &1})

      record = %{
        handle: handle,
        caller: caller,
        observer: observer,
        refs: refs,
        operation: RegistryContract.sanitize(operation),
        deadline: now() + remaining,
        sent: false,
        notified: false,
        error: nil,
        owed: 0,
        upload_planned: 0,
        response_bytes: 0,
        response_limit: min(budget.max_response_bytes, state.config.budget.max_response_bytes),
        timer: Process.send_after(self(), {:deadline, id, handle}, remaining),
        cancel_timer: nil
      }

      {:ok, handle,
       %{
         state
         | channel: channel,
           outbox: outbox,
           records: Map.put(state.records, id, record),
           handles: Map.put(state.handles, handle, id),
           monitors:
             Enum.reduce(refs, state.monitors, fn {ref, _pid}, acc -> Map.put(acc, ref, id) end),
           upload_reserved: state.upload_reserved + Map.get(operation, "total_bytes", 0)
       }}
    else
      _invalid -> failure(:admission_exhausted)
    end
  end

  defp approved?(config, request),
    do:
      CheckpointContract.opt_in_approved?(config, Map.get(request, "create", request)) and
        operation_approved?(config, request)

  defp operation_approved?(config, %{
         "operation" => "qualify_partial_branch_child_absence",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           PartialBranchChildAbsence.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "qualify_unbooted_branch_child_absence",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           UnbootedBranchChildAbsence.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "inspect_unbooted_branch_disposal",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           request["approval"] in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => name})
       when name in ~w(qualify_export admit_export export_machine inspect_export cleanup_export_staging),
       do: Features.supports?(config, :exports)

  defp operation_approved?(config, %{"operation" => operation, "create" => create})
       when operation in ~w(create inspect_creation) do
    create["artifact"] in Enum.map(config.artifacts, &Launch.artifact/1) and
      CreationFeatures.approved?(create["features"], config) and
      MountContract.approved?(create, config) and
      profile_approved?(config, create)
  end

  defp operation_approved?(config, %{"operation" => name, "create" => create})
       when name in ~w(create_oci inspect_oci_creation),
       do: source_approved?(config, create)

  defp operation_approved?(config, %{"operation" => name, "create" => create})
       when name in ~w(create_registry_prepared inspect_registry_creation),
       do:
         Features.supports?(config, :remote_sources) and NativeSource.registry_creation?(create) and
           create["source"] in Enum.map(config.sources, &Source.artifact/1) and
           CreationFeatures.approved?(create["features"], config) and
           MountContract.approved?(create, config) and
           profile_approved?(config, create)

  defp operation_approved?(config, %{"operation" => name, "create" => create})
       when name in ~w(create_checkpoint inspect_checkpoint_creation),
       do:
         Features.supports?(config, :checkpoints) and CheckpointContract.creation?(create) and
           CheckpointContract.approved?(config, create)

  defp operation_approved?(config, %{"operation" => "qualify_checkpoint_creation"} = request),
    do: Features.supports?(config, :checkpoints) and CheckpointContract.approved?(config, request)

  defp operation_approved?(config, %{"operation" => "qualify_oci_creation"} = request),
    do: source_approved?(config, request)

  defp operation_approved?(config, %{"operation" => "qualify_registry_creation"} = request),
    do:
      Features.supports?(config, :remote_sources) and
        NativeSource.registry_artifact?(request["source"]) and
        request["source"] in Enum.map(config.sources, &Source.artifact/1) and
        CreationFeatures.approved?(request["features"], config) and
        MountContract.approved?(request, config) and
        profile_approved?(config, request)

  defp operation_approved?(config, %{"operation" => "start_oci", "source" => source}),
    do:
      Features.supports?(config, :remote_sources) and NativeSource.artifact?(source) and
        source in Enum.map(config.sources, &Source.artifact/1)

  defp operation_approved?(config, %{"operation" => name})
       when name in ~w(health capacity metrics readiness list measurements),
       do: Features.supports?(config, :observability)

  defp operation_approved?(config, %{"operation" => name})
       when name in ~w(expand_disks inspect_growth qualify_growth),
       do: Features.supports?(config, :disk_growth)

  defp operation_approved?(config, %{"operation" => "qualify_creation"} = request),
    do: approved?(config, %{"operation" => "create", "create" => request})

  defp operation_approved?(config, %{"operation" => "exec_buffered"}),
    do: Features.supports?(config, :buffered_exec)

  defp operation_approved?(config, %{"operation" => "exec_background"}),
    do: Features.supports?(config, :background_exec)

  defp operation_approved?(config, %{"operation" => "exec_stream"}),
    do: Features.supports?(config, :streaming_exec)

  defp operation_approved?(config, %{"operation" => "volume", "request" => request}),
    do:
      config.platform == :linux and Features.supports?(config, :volumes) and
        VolumeContract.approved?(request, config.volume_policy)

  defp operation_approved?(config, %{"operation" => "terminal_preflight"}),
    do: Features.supports?(config, :terminal_preflight)

  defp operation_approved?(config, %{"operation" => "terminal_open"}),
    do: Features.supports?(config, :terminals)

  defp operation_approved?(
         config,
         %{"operation" => "prepare_artifact", "source" => source} = request
       ),
       do:
         Features.supports?(config, :remote_sources) and
           Enum.any?(config.sources, fn approved ->
             approved.kind == :registry and approved.credential_ref == request["credential_ref"] and
               RegistryContract.source(approved) == source
           end)

  defp operation_approved?(config, %{"operation" => "pull_image", "source" => source}),
    do:
      Features.supports?(config, :images) and
        Enum.any?(config.sources, fn approved ->
          approved.kind == :oci and ImageContract.source(approved) == source
        end)

  defp operation_approved?(config, %{"operation" => "list_images"}),
    do: Features.supports?(config, :images)

  defp operation_approved?(config, %{"operation" => name})
       when name in ~w(start_checkpointable checkpoint_preflight inspect_capture inspect_capture_resolution resolve_capture cleanup_capture_staging abort_capture_staging qualify_aborted_capture_source capture_checkpoint),
       do: Features.supports?(config, :checkpoints)

  defp operation_approved?(config, %{"operation" => name, "request" => request})
       when name in ~w(dispose_unbooted_branch resolve_unbooted_branch_disposal),
       do:
         Features.supports?(config, :branches) and
           UnbootedBranchDisposal.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "release_unbooted_branch_backing",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           UnbootedBranchBackingRelease.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "release_partial_branch_backing",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           PartialBranchBackingRelease.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "retire_prepared_branch",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           PreparedBranchRetirement.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => name, "request" => request})
       when name in ~w(continue_held_branch_deletion cleanup_held_branch_deletion),
       do:
         Features.supports?(config, :branches) and
           HeldBranchDeletionAction.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "continue_released_branch_deletion",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           ReleasedBranchDeletionContinuation.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "cleanup_released_branch_deletion",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           ReleasedBranchDeletionCleanup.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => name, "request" => request})
       when name in ~w(dispose_partial_branch resolve_partial_branch_disposal qualify_partial_branch_cleanup),
       do:
         Features.supports?(config, :branches) and
           PartialBranchDisposal.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => name,
         "request" => request
       })
       when name in ~w(cleanup_partial_branch_disposal resolve_partial_branch_cleanup),
       do:
         Features.supports?(config, :branches) and
           (name != "resolve_partial_branch_cleanup" or
              Features.supports?(config, :partial_cleanup_resolution)) and
           PartialBranchDisposalCleanup.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => name,
         "request" => request
       })
       when name in ~w(collect_partial_branch inspect_partial_branch_collection),
       do:
         Features.supports?(config, :branches) and
           (name != "inspect_partial_branch_collection" or
              Features.supports?(config, :partial_collection_preflight)) and
           PartialBranchCollection.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "collect_branch_deletion",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           BranchDeletionCollection.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "resolve_released_branch_deletion",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           ReleasedBranchDeletionResolution.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "resolve_held_branch_deletion",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           BranchDeletionResolution.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "release_branch_backing",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           BranchBackingRelease.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{
         "operation" => "qualify_branch_child_absence",
         "request" => request
       }),
       do:
         Features.supports?(config, :branches) and
           BranchChildAbsence.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => "branch_preflight"}),
    do: Features.supports?(config, :branches)

  defp operation_approved?(config, %{"operation" => name, "request" => request})
       when name in ~w(release_held_branch qualify_held_branch_release),
       do:
         Features.supports?(config, :branches) and
           HeldBranchReleaseRequest.approval(request) in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => name, "request" => request})
       when name in ~w(create_branch inspect_branch_completion resolve_ready_branch_completion publish_collected_branch_material),
       do:
         Features.supports?(config, :branches) and
           request["approval"] in BranchRequest.approvals(config)

  defp operation_approved?(config, %{"operation" => "logs"}),
    do: Features.supports?(config, :logs)

  defp operation_approved?(_config, _operation), do: true

  defp source_approved?(config, request),
    do:
      Features.supports?(config, :remote_sources) and NativeSource.artifact?(request["source"]) and
        request["source"] in Enum.map(config.sources, &Source.artifact/1) and
        CreationFeatures.approved?(request["features"], config) and
        MountContract.approved?(request, config) and
        profile_approved?(config, request)

  defp profile_approved?(config, create) do
    Enum.any?(config.profiles, fn profile ->
      Map.get(create, "features", %{})
      |> Map.get("network", %{"enabled" => false, "hosts" => [], "cidrs" => []}) ==
        CreationFeatures.network(profile.network) and
        create["resources"] == %{
          "cpus" => profile.cpus,
          "memory_mib" => profile.memory_mb,
          "storage_gib" => profile.storage_gb,
          "overlay_gib" => profile.overlay_gb
        }
    end)
  end

  defp receive_body(%{status: :handshaking} = state, body) do
    with {:ok, %{"type" => "hello", "hello" => hello}} <-
           Protocol.decode(body, state.protocol_major),
         true <- Protocol.approve(hello, state.config, Config.sdk_identity(state.config)),
         true <- hello["minor"] == state.protocol_minor,
         {:ok, outbox} <-
           Outbox.put(
             state.outbox,
             %{kind: :approve, id: nil, message: %{"type" => "approve", "hello" => hello}},
             state.config.limits.send_queue_bytes
           ) do
      cancel_timer(state.startup_timer)

      {:ok,
       %{
         state
         | channel: Channel.new(hello),
           outbox: outbox,
           status: :approving,
           startup_token: nil,
           startup_timer: nil
       }}
    else
      _invalid -> :error
    end
  end

  defp receive_body(%{closing: true} = state, _body), do: {:ok, state}

  defp receive_body(state, body) do
    with {:ok, message} <- Protocol.decode(body, state.protocol_major),
         {:ok, channel, event} <- Channel.receive_message(state.channel, message) do
      receive_correlated(%{state | channel: channel}, event, byte_size(body))
    else
      _invalid -> :error
    end
  end

  defp receive_correlated(state, :unavailable, _bytes),
    do: {:ok, %{state | status: :quarantined}}

  defp receive_correlated(state, {id, event}, bytes) do
    with {:ok, record} <- Map.fetch(state.records, id),
         true <- record.sent,
         true <- catalog_result?(state.config, event) do
      # Terminals and captures are consumed streams. Bound each encoded frame;
      # Channel enforces unread byte/event credit and the operation's total proof.
      charged =
        if record.operation["operation"] in ~w(terminal_open capture_checkpoint),
          do: max(record.response_bytes, bytes),
          else: record.response_bytes + bytes

      record = %{record | response_bytes: charged}
      state = %{state | records: Map.put(state.records, id, record)}

      state =
        if record.response_bytes > record.response_limit,
          do: cancel_request(state, id, :output_limit),
          else: state

      {:ok, deliver(state, id, event)}
    else
      _invalid -> :error
    end
  end

  defp catalog_result?(config, {:terminal, %{"result" => "volume"} = outcome}),
    do: VolumeContract.approved_result?(outcome, config.volume_policy)

  defp catalog_result?(_config, _event), do: true

  defp receive_next(body, state) do
    case receive_body(state, body) do
      {:ok, state} -> {:cont, state}
      :error -> {:halt, protocol_failure(state)}
    end
  end

  defp deliver(state, id, :accepted) do
    notify(state.records[id], :accepted)
    state
  end

  defp deliver(state, id, :terminal_opened) do
    record = state.records[id]
    if record.error == nil, do: notify(record, :terminal_opened)
    state
  end

  defp deliver(state, id, {:output, _stream, bytes} = event) do
    record = state.records[id]

    if record.observer && record.error == nil do
      notify(record, event)

      %{
        state
        | records: Map.put(state.records, id, %{record | owed: record.owed + byte_size(bytes)})
      }
    else
      drain_if_unowed(state, id)
    end
  end

  defp deliver(state, id, {:terminal, outcome}) do
    record = state.records[id]
    cancel_timer(record.timer)
    cancel_timer(record.cancel_timer)
    notify(record, {:terminal, outcome, record.error})

    state = %{
      state
      | records: Map.put(state.records, id, %{record | notified: true}),
        outbox: Outbox.drop_request(state.outbox, id)
    }

    retire_if_consumed(drain_if_unowed(state, id), id)
  end

  defp consume(state, id, bytes) do
    with {:ok, channel, credit} <- Channel.acknowledge(state.channel, id, bytes) do
      record = state.records[id]

      state = %{
        state
        | channel: channel,
          records: Map.put(state.records, id, %{record | owed: record.owed - bytes})
      }

      state = if credit.native_credit, do: credit(state, id, bytes, credit.events), else: state
      {:ok, drain_if_unowed(state, id)}
    end
  end

  defp drain_if_unowed(state, id) do
    record = state.records[id]
    pending = state.channel.pending[id]

    if record.owed == 0 and pending.unacknowledged > 0 and
         (record.error != nil or record.observer == nil) do
      {:ok, channel, credit} = Channel.acknowledge(state.channel, id, pending.unacknowledged)
      state = %{state | channel: channel}

      if credit.native_credit and not state.closing,
        do: credit(state, id, pending.unacknowledged, credit.events),
        else: state
    else
      state
    end
  end

  defp credit(state, id, bytes, events),
    do: control(state, :credit, id, %{"decoded_bytes" => bytes, "events" => events})

  defp cancel_request(state, id, category) do
    record = state.records[id]

    cond do
      record.notified ->
        state

      record.error != nil ->
        state

      not record.sent ->
        {:ok, channel} = Channel.reject_unsent(state.channel, id)
        error = %Error{category: category, operation: :embedded}
        notify(record, {:bridge_error, error})

        retire_if_consumed(
          %{
            state
            | channel: channel,
              outbox: Outbox.drop_request(state.outbox, id),
              records: Map.put(state.records, id, %{record | notified: true, error: error})
          },
          id
        )

      true ->
        error = error_for(state, id, category)

        timer =
          Process.send_after(
            self(),
            {:cancel_timeout, id, record.handle},
            state.config.limits.cancel_grace_ms
          )

        state = %{
          state
          | outbox: Outbox.drop_request(state.outbox, id),
            records: Map.put(state.records, id, %{record | error: error, cancel_timer: timer})
        }

        control(state, :cancel, id, %{})
    end
  end

  defp observer_down(state, id, ref) do
    record = state.records[id]
    pid = record.refs[ref]

    record = %{
      record
      | refs: Map.delete(record.refs, ref),
        caller: if(record.caller == pid, do: nil, else: record.caller),
        observer: if(record.observer == pid, do: nil, else: record.observer)
    }

    record = if record.observer == nil, do: %{record | owed: 0}, else: record

    state = %{
      state
      | records: Map.put(state.records, id, record),
        monitors: Map.delete(state.monitors, ref)
    }

    state = cancel_request(state, id, :unknown)

    if Map.has_key?(state.records, id),
      do: retire_if_consumed(drain_if_unowed(state, id), id),
      else: state
  end

  defp retire_if_consumed(state, id) do
    case Channel.retire(state.channel, id) do
      {:ok, channel} ->
        record = state.records[id]
        cancel_timer(record.timer)
        cancel_timer(record.cancel_timer)
        Enum.each(record.refs, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

        %{
          state
          | channel: channel,
            records: Map.delete(state.records, id),
            handles: Map.delete(state.handles, record.handle),
            monitors: Map.drop(state.monitors, Map.keys(record.refs)),
            upload_reserved: state.upload_reserved - Map.get(record.operation, "total_bytes", 0)
        }

      _pending ->
        state
    end
  end

  defp control(state, kind, id, fields) do
    message = Map.merge(%{"type" => Atom.to_string(kind), "epoch" => state.channel.epoch}, fields)
    message = if id, do: Map.put(message, "id", id), else: message

    case Outbox.put(
           state.outbox,
           %{kind: kind, id: id, message: message},
           state.config.limits.send_queue_bytes
         ) do
      {:ok, outbox} -> %{state | outbox: outbox}
      :error -> protocol_failure(state)
    end
  end

  defp flush(%{port: nil} = state, _count), do: state
  defp flush(state, count) when count >= 64, do: schedule_flush(state)

  defp flush(state, count) do
    case Outbox.next(state.outbox) do
      :empty ->
        state

      {:ok, entry} ->
        case send_entry(state, entry) do
          {:ok, state} -> flush(state, count + 1)
          {:busy, state} -> schedule_flush(state)
          {:failed, state} -> begin_close(close_channel(state, :transport))
        end
    end
  end

  defp send_entry(state, %{kind: :request, id: id} = entry) do
    record = state.records[id]
    remaining = record.deadline - now()

    if remaining <= 0 do
      {:ok, cancel_request(state, id, :expired)}
    else
      message = Map.put(entry.message, "budget_ms", remaining)
      {:ok, encoded} = JSON.encode(message)
      send_encoded(state, %{entry | encoded: encoded})
    end
  end

  defp send_entry(state, entry), do: send_encoded(state, entry)

  defp send_encoded(state, entry) do
    case :erlang.port_command(state.port, entry.encoded, [:nosuspend]) do
      true -> {:ok, sent(%{state | outbox: Outbox.pop(state.outbox)}, entry)}
      false -> {:busy, state}
    end
  rescue
    _redacted -> {:failed, state}
  end

  defp sent(state, %{kind: :request, id: id}),
    do: %{state | records: Map.update!(state.records, id, &%{&1 | sent: true})}

  defp sent(state, %{kind: :upload, id: id, decoded_bytes: bytes}) do
    {:ok, channel} = Channel.uploaded(state.channel, id, bytes)
    %{state | channel: channel}
  end

  defp sent(state, %{kind: :approve}), do: %{state | status: :reconciling}
  defp sent(state, _entry), do: state

  defp open(state) do
    cancel_timer(state.restart_timer)

    case Launch.directory() do
      {:ok, directory} ->
        Launch.remember(state.cleanup_watcher, directory)
        token = make_ref()
        owner = self()
        config = state.config

        pid =
          spawn_link(fn -> send(owner, {:prepared, token, Launch.prepare(config, directory)}) end)

        timer = Process.send_after(self(), {:startup_timeout, token}, config.limits.handshake_ms)

        {:noreply,
         %{
           state
           | directory: directory,
             preparing: pid,
             status: :starting,
             startup_token: token,
             startup_timer: timer,
             restart_timer: nil,
             closing: false
         }}

      _failed ->
        {:noreply, failed_start(state)}
    end
  end

  defp failed_start(state) do
    cancel_timer(state.startup_timer)
    Launch.cleanup(state.directory)

    restart_later(%{
      state
      | status: :unavailable,
        directory: nil,
        startup_token: nil,
        startup_timer: nil
    })
  end

  defp protocol_failure(state), do: begin_close(close_channel(state, :protocol))

  defp close_channel(state, category) do
    if state.channel do
      channel = Channel.close(state.channel)

      state =
        Enum.reduce(state.records, %{state | channel: channel}, &close_record(&1, &2, category))

      %{state | status: :unavailable, outbox: %Outbox{}}
    else
      %{state | status: :unavailable, outbox: %Outbox{}}
    end
  end

  defp close_record({id, record}, state, category) do
    if not record.notified,
      do: notify(record, {:channel_lost, record.error || error_for(state, id, category)})

    cancel_timer(record.timer)
    cancel_timer(record.cancel_timer)
    record = %{record | notified: true}
    state = %{state | records: Map.put(state.records, id, record)}
    retire_if_consumed(drain_if_unowed(state, id), id)
  end

  defp begin_close(%{port: nil} = state) do
    if state.preparing, do: Process.exit(state.preparing, :kill)
    failed_start(%{state | preparing: nil})
  end

  defp begin_close(%{closing: true} = state), do: state

  defp begin_close(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:close_timeout, token}, state.config.limits.shutdown_ms)

    state = %{
      state
      | closing: true,
        status: :closing,
        shutdown_token: token,
        shutdown_timer: timer
    }

    if state.channel,
      do: schedule_flush(control(state, :shutdown, nil, %{})),
      else: state
  end

  defp port_exited(state) do
    cancel_timer(state.shutdown_timer)
    cancel_timer(state.startup_timer)

    state =
      close_channel(state, if(Frame.complete?(state.frame), do: :transport, else: :protocol))

    Launch.cleanup(state.directory)

    state = %{
      state
      | port: nil,
        directory: nil,
        closing: false,
        shutdown_token: nil,
        startup_token: nil,
        frame: %Frame{},
        outbox: %Outbox{}
    }

    if state.shutting_down, do: %{state | status: :stopped}, else: restart_later(state)
  end

  defp restart_later(%{shutting_down: true} = state), do: %{state | status: :stopped}
  defp restart_later(%{restart_timer: timer} = state) when timer != nil, do: state

  defp restart_later(state) do
    timer = Process.send_after(self(), :open, state.backoff_ms)
    %{state | restart_timer: timer, backoff_ms: min(state.backoff_ms * 2, 30_000)}
  end

  defp schedule_flush(%{flush_timer: nil, port: port} = state) when port != nil,
    do: %{state | flush_timer: Process.send_after(self(), :flush, 5)}

  defp schedule_flush(state), do: state
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp notify(%{observer: nil}, _event), do: :ok
  defp notify(record, event), do: send(record.observer, {:smolbox_embedded, record.handle, event})

  defp lookup(state, handle) do
    with {:ok, id} <- Map.fetch(state.handles, handle),
         {:ok, record} <- Map.fetch(state.records, id),
         do: {:ok, id, record}
  end

  defp error_for(state, id, category) do
    record = state.records[id]
    pending = state.channel.pending[id]

    evidence =
      cond do
        pending.output_bytes > 0 -> :running_observed
        record.sent -> :dispatch_uncertain
        true -> :not_dispatched
      end

    %Error{category: category, operation: :embedded, evidence: evidence}
  end

  defp failure(category, evidence \\ :not_dispatched),
    do: {:error, %Error{category: category, operation: :embedded, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
  defp close_port(nil), do: :ok

  defp close_port(port) do
    :erlang.port_close(port)
  rescue
    _closed -> :ok
  end

  @impl true
  def terminate(_reason, state) do
    if state.preparing, do: Process.exit(state.preparing, :kill)
    close_port(state.port)
    Launch.cleanup(state.directory)
    :ok
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, [])
end
