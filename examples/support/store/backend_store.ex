defmodule SmolBox.DurableHost.BackendStore do
  @moduledoc false
  alias SmolBox.Store.{MachineOps, RecordOps}

  if Code.ensure_loaded?(SmolBox.Store.BackendAssignments) do
    alias SmolBox.DurableHost.Database
    alias SmolBox.Store.BackendAssignments

    def assignments(context, worker, cursor, limit) do
      if BackendAssignments.valid_page?(worker, cursor, limit) do
        with {:ok, records} <- Database.assignment_records(context, cursor, limit),
             do: BackendAssignments.page(records, worker, cursor, limit)
      else
        {:error, %SmolBox.Error{category: :validation, operation: :backend_assignments}}
      end
    end
  end

  if Code.ensure_loaded?(SmolBox.Store.BackendBindings) do
    alias SmolBox.Backend.Binding
    alias SmolBox.DurableHost.{Database, KubernetesBinding}
    alias SmolBox.Error

    alias SmolBox.Store.{
      BackendBindings,
      CodecCheckpointable,
      CodecGrowth,
      CodecMaterial,
      CodecNativeCaptureAbortSources,
      CodecNativeCaptureCleanup,
      CodecNativeCaptureResolutions,
      CodecNativeCaptures,
      CodecNativeCheckpoints,
      CodecNativeExports,
      CodecNativeSources
    }

    def capabilities(context) do
      Database.query(
        context,
        "SELECT kind,generation,payload FROM smolbox_backend_bindings LIMIT 0",
        []
      )

      capabilities =
        if function_exported?(__MODULE__, :assignments, 4),
          do: %{backend_bindings: 1, backend_recovery: 1, kubernetes_backend: 1},
          else: %{backend_bindings: 1}

      capabilities =
        if Code.ensure_loaded?(CodecMaterial),
          do: Map.put(capabilities, :native_material_proofs, 2),
          else: capabilities

      capabilities
      |> background_capabilities()
      |> streaming_capabilities()
      |> terminal_capabilities()
      |> growth_capabilities()
      |> source_capabilities()
      |> checkpoint_capabilities()
      |> export_capabilities()
    end

    if Code.ensure_loaded?(CodecMaterial) and
         function_exported?(CodecMaterial, :background_launches, 0) do
      defp background_capabilities(capabilities),
        do:
          Map.put(
            capabilities,
            :native_background_launches,
            CodecMaterial.background_launches()
          )
    else
      defp background_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecMaterial) and
         function_exported?(CodecMaterial, :streaming_commands, 0) do
      defp streaming_capabilities(capabilities),
        do: Map.put(capabilities, :native_streaming_commands, CodecMaterial.streaming_commands())
    else
      defp streaming_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecMaterial) and
         function_exported?(CodecMaterial, :terminal_sessions, 0) do
      defp terminal_capabilities(capabilities),
        do: Map.put(capabilities, :native_terminal_sessions, CodecMaterial.terminal_sessions())
    else
      defp terminal_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecGrowth) and function_exported?(CodecGrowth, :reader, 0) do
      defp growth_capabilities(capabilities),
        do: Map.put(capabilities, :native_disk_growth, CodecGrowth.reader())
    else
      defp growth_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeSources) and
         function_exported?(CodecNativeSources, :reader, 0) do
      defp source_capabilities(capabilities),
        do: Map.put(capabilities, :native_sources, CodecNativeSources.reader())
    else
      defp source_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeCheckpoints) and
         function_exported?(CodecNativeCheckpoints, :reader, 0) do
      defp checkpoint_capabilities(capabilities),
        do:
          checkpointable_capabilities(
            Map.put(capabilities, :native_checkpoint_sources, CodecNativeCheckpoints.reader())
          )
    else
      defp checkpoint_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecCheckpointable) and
         function_exported?(CodecCheckpointable, :reader, 0) do
      defp checkpointable_capabilities(capabilities),
        do:
          capture_capabilities(
            Map.put(capabilities, :native_checkpointable, CodecCheckpointable.reader())
          )
    else
      defp checkpointable_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeCaptures) and
         function_exported?(CodecNativeCaptures, :reader, 0) do
      defp capture_capabilities(capabilities),
        do:
          capture_resolution_capabilities(
            Map.put(capabilities, :native_capture_histories, CodecNativeCaptures.reader())
          )
    else
      defp capture_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeCaptureResolutions) and
         function_exported?(CodecNativeCaptureResolutions, :reader, 0) do
      defp capture_resolution_capabilities(capabilities),
        do:
          capture_cleanup_capabilities(
            Map.put(
              capabilities,
              :native_capture_resolutions,
              CodecNativeCaptureResolutions.reader()
            )
          )
    else
      defp capture_resolution_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeCaptureCleanup) and
         function_exported?(CodecNativeCaptureCleanup, :reader, 0) do
      defp capture_cleanup_capabilities(capabilities),
        do:
          capture_abort_source_capabilities(
            Map.put(capabilities, :native_capture_cleanup, CodecNativeCaptureCleanup.reader())
          )
    else
      defp capture_cleanup_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeCaptureAbortSources) and
         function_exported?(CodecNativeCaptureAbortSources, :reader, 0) do
      defp capture_abort_source_capabilities(capabilities),
        do:
          Map.put(
            capabilities,
            :native_capture_abort_sources,
            CodecNativeCaptureAbortSources.reader()
          )
    else
      defp capture_abort_source_capabilities(capabilities), do: capabilities
    end

    if Code.ensure_loaded?(CodecNativeExports) and
         function_exported?(CodecNativeExports, :reader, 0) do
      defp export_capabilities(capabilities),
        do: Map.put(capabilities, :native_export_histories, CodecNativeExports.reader())
    else
      defp export_capabilities(capabilities), do: capabilities
    end

    def reserve_execution(record, worker, name, lease, capacity, used, now, assignment),
      do:
        RecordOps.reservation(
          record,
          worker,
          name,
          lease,
          capacity,
          used,
          now,
          assignment
        )

    def reserve_machine(record, worker, name, lease, capacity, used, now, assignment),
      do:
        MachineOps.reserve(
          record,
          worker,
          name,
          lease,
          capacity,
          used,
          now,
          assignment
        )

    # All callers hold the partition lock, shared with assignment transactions.
    def bind(context, worker, binding) do
      with {:ok, current} <- read(context, worker),
           {:ok, evidence} <- Database.assignment_backend(context, worker),
           {:ok, next} <-
             BackendBindings.bind(worker, current, binding, evidence),
           :ok <- available(context, worker, next) do
        {kind, generation, payload} = columns(context, next)

        Database.query(
          context,
          """
          INSERT INTO smolbox_backend_bindings (partition,worker_id,kind,generation,payload)
          VALUES ($1,$2,$3,$4,$5) ON CONFLICT (partition,worker_id) DO UPDATE SET
            kind=EXCLUDED.kind,generation=EXCLUDED.generation,payload=EXCLUDED.payload
          """,
          [context.partition, worker, kind, generation, payload]
        )

        {:ok, next}
      else
        {:error, _error} = error -> error
        _unavailable -> error(:identity_conflict)
      end
    end

    def allocation(context, allocation) do
      worker = BackendBindings.worker(allocation)

      with {:ok, binding} <- read(context, worker),
           :ok <- unbound(context, worker, binding),
           do: BackendBindings.allocation(allocation, binding)
    end

    def http(context, worker) do
      with {:ok, binding} <- read(context, worker),
           :ok <- unbound(context, worker, binding),
           do: BackendBindings.http(binding)
    end

    def volume(context, v) do
      if function_exported?(BackendBindings, :volume, 2) do
        with {:ok, binding} <- read(context, v.worker_id),
             :ok <- unbound(context, v.worker_id, binding),
             do: BackendBindings.volume(binding, v)
      else
        legacy_volume(context, v)
      end
    end

    defp legacy_volume(context, v),
      do:
        if(Map.get(v, :native_authority) == nil,
          do: http(context, v.worker_id),
          else: error(:unsupported_capability)
        )

    def mounts(context, machine) do
      if function_exported?(BackendBindings, :mounts, 2) do
        with {:ok, binding} <- read(context, machine.volume_worker_id),
             :ok <- unbound(context, machine.volume_worker_id, binding),
             do: BackendBindings.mounts(binding, machine)
      else
        legacy_mounts(context, machine)
      end
    end

    defp legacy_mounts(context, machine),
      do:
        if(Map.get(machine, :native_mounts, []) == [],
          do: http(context, machine.volume_worker_id),
          else: error(:unsupported_capability)
        )

    defp unbound(context, worker, nil) do
      with {:ok, evidence} <- Database.assignment_backend(context, worker),
           do: BackendBindings.unbound(evidence)
    end

    defp unbound(_context, _worker, _binding), do: :ok

    def read(context, worker) do
      rows =
        Database.query(
          context,
          "SELECT kind,generation,payload FROM smolbox_backend_bindings WHERE partition=$1 AND worker_id=$2",
          [context.partition, worker]
        ).rows

      decode(context, worker, rows)
    end

    defp decode(_context, _worker, []), do: {:ok, nil}
    defp decode(_context, _worker, [["http", nil, nil]]), do: {:ok, :http}

    defp decode(_context, worker, [["embedded", generation, nil]]) do
      binding = %Binding{kind: :embedded, target_id: worker, generation: generation}
      if Binding.valid?(binding), do: {:ok, binding}, else: error(:store)
    end

    defp decode(context, worker, [["kubernetes", generation, payload]]),
      do: KubernetesBinding.decrypt(context, worker, generation, payload)

    defp decode(_context, _worker, _rows), do: error(:store)
    defp columns(_context, :http), do: {"http", nil, nil}
    defp columns(_context, %Binding{generation: generation}), do: {"embedded", generation, nil}

    defp columns(context, %SmolBox.Kubernetes.Binding{} = binding),
      do: {"kubernetes", binding.generation, KubernetesBinding.encrypt(context, binding)}

    defp available(_context, _worker, :http), do: :ok

    defp available(context, worker, %SmolBox.Kubernetes.Binding{} = binding) do
      with :ok <- available_page(context, worker, binding, nil),
           do: Database.assignment_domain_available(context, worker, binding)
    end

    defp available(context, worker, %Binding{generation: generation}) do
      rows =
        Database.query(
          context,
          "SELECT worker_id FROM smolbox_backend_bindings WHERE partition=$1 AND generation=$2 AND worker_id<>$3",
          [context.partition, generation, worker]
        ).rows

      if rows == [],
        do: Database.assignment_domain_available(context, worker, generation),
        else: error(:identity_conflict)
    end

    defp available_page(context, worker, binding, cursor) do
      rows =
        Database.query(
          context,
          "SELECT worker_id,kind,generation,payload FROM smolbox_backend_bindings WHERE partition=$1 " <>
            "AND ($2::varchar IS NULL OR worker_id>$2) ORDER BY worker_id LIMIT 100",
          [context.partition, cursor]
        ).rows

      with :ok <- available_rows(context, worker, binding, rows) do
        if Enum.count_until(rows, 100) == 100,
          do: available_page(context, worker, binding, rows |> List.last() |> hd()),
          else: :ok
      end
    end

    defp available_rows(context, worker, binding, rows) do
      Enum.reduce_while(rows, :ok, fn [other | values], :ok ->
        with {:ok, existing} <- decode(context, other, [values]),
             true <- BackendBindings.available?([{other, existing}], worker, binding) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, error(:identity_conflict)}
        end
      end)
    end

    defp error(category), do: {:error, %Error{category: category, operation: :reservation}}
  else
    def capabilities(_context), do: %{}
    def allocation(_context, {worker, name, capacity}), do: {:ok, worker, name, capacity, nil}
    def http(_context, _worker), do: :ok

    def mounts(context, machine),
      do:
        if(Map.get(machine, :native_mounts, []) == [],
          do: http(context, machine.volume_worker_id),
          else: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :volume}}
        )

    def volume(context, v),
      do:
        if(Map.get(v, :native_authority) == nil,
          do: http(context, v.worker_id),
          else: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :volume}}
        )

    def reserve_execution(record, worker, name, lease, capacity, used, now, nil),
      do: RecordOps.reservation(record, worker, name, lease, capacity, used, now)

    def reserve_machine(record, worker, name, lease, capacity, used, now, nil),
      do: MachineOps.reserve(record, worker, name, lease, capacity, used, now)
  end
end
