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
    alias SmolBox.DurableHost.Database
    alias SmolBox.Error
    alias SmolBox.Store.{BackendBindings, CodecGrowth, CodecMaterial, CodecNativeSources}

    def capabilities(context) do
      Database.query(context, "SELECT kind,generation FROM smolbox_backend_bindings LIMIT 0", [])

      capabilities =
        if function_exported?(__MODULE__, :assignments, 4),
          do: %{backend_bindings: 1, backend_recovery: 1},
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
        {kind, generation} = columns(next)

        Database.query(
          context,
          """
          INSERT INTO smolbox_backend_bindings (partition,worker_id,kind,generation)
          VALUES ($1,$2,$3,$4) ON CONFLICT (partition,worker_id) DO UPDATE SET
            kind=EXCLUDED.kind,generation=EXCLUDED.generation
          """,
          [context.partition, worker, kind, generation]
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

    defp unbound(context, worker, nil) do
      with {:ok, evidence} <- Database.assignment_backend(context, worker),
           do: BackendBindings.unbound(evidence)
    end

    defp unbound(_context, _worker, _binding), do: :ok

    def read(context, worker) do
      rows =
        Database.query(
          context,
          "SELECT kind,generation FROM smolbox_backend_bindings WHERE partition=$1 AND worker_id=$2",
          [context.partition, worker]
        ).rows

      decode(worker, rows)
    end

    defp decode(_worker, []), do: {:ok, nil}
    defp decode(_worker, [["http", nil]]), do: {:ok, :http}

    defp decode(worker, [["embedded", generation]]) do
      binding = %Binding{kind: :embedded, target_id: worker, generation: generation}
      if Binding.valid?(binding), do: {:ok, binding}, else: error(:store)
    end

    defp decode(_worker, _rows), do: error(:store)
    defp columns(:http), do: {"http", nil}
    defp columns(%Binding{generation: generation}), do: {"embedded", generation}

    defp available(_context, _worker, :http), do: :ok

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

    defp error(category), do: {:error, %Error{category: category, operation: :reservation}}
  else
    def capabilities(_context), do: %{}
    def allocation(_context, {worker, name, capacity}), do: {:ok, worker, name, capacity, nil}
    def http(_context, _worker), do: :ok

    def reserve_execution(record, worker, name, lease, capacity, used, now, nil),
      do: RecordOps.reservation(record, worker, name, lease, capacity, used, now)

    def reserve_machine(record, worker, name, lease, capacity, used, now, nil),
      do: MachineOps.reserve(record, worker, name, lease, capacity, used, now)
  end
end
