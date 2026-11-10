defmodule SmolBox.DurableHost.BranchStore do
  @moduledoc false
  if Code.ensure_loaded?(SmolBox.Store.BranchOps) do
    alias SmolBox.DurableHost.{Database, WorkerStore}

    alias SmolBox.Store.{
      BranchOps,
      CodecNativeCollectedBranchPublications,
      CodecNativePartialBranchBackings,
      CodecNativePartialBranchCleanupResolutions,
      CodecNativePartialBranchCleanups,
      CodecNativePartialBranchCollections,
      CodecNativePartialBranchDisposals,
      CodecNativePartialBranchRetirements,
      CodecStaticBranchEgress,
      NativeBranchReleaseOps
    }

    def capabilities do
      supported = %{managed_branches: 1}

      supported =
        if Code.ensure_loaded?(BranchOps) and function_exported?(BranchOps, :release, 4),
          do: Map.put(supported, :branch_release_env, 1),
          else: supported

      readers = [
        {:native_collected_branch_publications, CodecNativeCollectedBranchPublications},
        {:native_partial_branch_collections, CodecNativePartialBranchCollections},
        {:native_partial_branch_disposals, CodecNativePartialBranchDisposals},
        {:native_partial_branch_retirements, CodecNativePartialBranchRetirements},
        {:native_partial_branch_backings, CodecNativePartialBranchBackings},
        {:native_partial_branch_cleanups, CodecNativePartialBranchCleanups},
        {:native_partial_branch_cleanup_resolutions, CodecNativePartialBranchCleanupResolutions}
      ]

      supported =
        if Code.ensure_loaded?(CodecStaticBranchEgress),
          do: Map.put(supported, :branch_static_egress, CodecStaticBranchEgress.reader()),
          else: supported

      supported =
        Enum.reduce(
          readers,
          supported,
          fn {marker, reader}, acc ->
            if Code.ensure_loaded?(reader), do: Map.put(acc, marker, reader.reader()), else: acc
          end
        )

      if Code.ensure_loaded?(NativeBranchReleaseOps) and
           Enum.all?(readers, fn {marker, _reader} -> supported[marker] == 1 end),
         do: Map.put(supported, :native_branches, 1),
         else: supported
    end

    def run(context, :branch_accept, [key, spec, fingerprint, name, capacity, now]) do
      case Database.read(context, {elem(key, 0), spec.id}, :machine) do
        {:ok, %{fingerprint: ^fingerprint, branch: %{source: ^key}} = c} ->
          {:ok, nil, c}

        {:error, %{category: :not_found}} ->
          with {:ok, p} <- Database.read(context, key, :machine),
               :ok <- WorkerStore.admit(context, p.worker_id),
               {:ok, usage} <- Database.usage(context, p.worker_id),
               do: BranchOps.accept(p, spec, fingerprint, name, capacity, usage, now)

        {:ok, _} ->
          {:error, %SmolBox.Error{category: :identity_conflict, operation: :branch}}

        error ->
          error
      end
    end

    def run(context, :branch_advance, [key, guard, id, expected, change, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           do: BranchOps.advance(p, c, expected, change, now)
    end

    def run(context, :branch_resolve, [key, guard, id, source, observed, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           do: BranchOps.resolve(p, c, source, observed, now)
    end

    if function_exported?(BranchOps, :accept_backing, 5) and
         function_exported?(BranchOps, :retire, 4) and
         function_exported?(BranchOps, :release_storage, 4) do
      def run(context, :branch_retire, [key, guard, id, proof, now]) do
        with {:ok, p, c} <- pair(context, key, guard, id, now),
             do: BranchOps.retire(p, c, proof, now)
      end

      def run(context, :branch_backing_accept, [key, guard, id, version, removed, now]) do
        with {:ok, p, c} <- pair(context, key, guard, id, now),
             do: BranchOps.accept_backing(p, c, version, removed, now)
      end

      def run(context, :branch_release_storage, [key, guard, id, proof, now]) do
        with {:ok, p, c} <- pair(context, key, guard, id, now),
             do: BranchOps.release_storage(p, c, proof, now)
      end
    else
      def run(_context, operation, [_, _, _, _, _])
          when operation in [:branch_retire, :branch_release_storage],
          do: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :store}}

      def run(_context, :branch_backing_accept, [_, _, _, _, _, _]),
        do: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :store}}
    end

    def run(context, :branch_retire, [key, guard, id, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now), do: BranchOps.retire(p, c, now)
    end

    def run(context, :branch_release_storage, [key, guard, id, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           {:ok, c} <- BranchOps.release_storage(p, c, now),
           do: {:ok, nil, c}
    end

    def run(context, :branch_release, [key, version, now]) do
      with {:ok, c} <- Database.read(context, key, :machine),
           do: accept_release(context, c, [version, now])
    end

    def run(context, :branch_release, [key, version, env, now]) do
      with {:ok, c} <- Database.read(context, key, :machine),
           do: accept_release(context, c, [version, env, now])
    end

    def run(context, :branch_release_advance, [key, guard, expected, change, now]) do
      with {:ok, c} <- Database.guarded_machine(context, key, guard, now),
           do: advance_release(context, c, expected, change, now)
    end

    defp accept_release(context, %{branch: %{native_authority: authority}} = c, arguments)
         when not is_nil(authority),
         do: native_release(context, c, :accept, arguments)

    defp accept_release(_context, c, arguments),
      do: with({:ok, c} <- apply(BranchOps, :release, [c | arguments]), do: {:ok, nil, c})

    defp advance_release(
           context,
           %{branch: %{native_authority: authority}} = c,
           expected,
           change,
           now
         )
         when not is_nil(authority),
         do: native_release(context, c, :advance, [expected, change, now])

    defp advance_release(_context, c, expected, change, now),
      do: with({:ok, c} <- BranchOps.release_advance(c, expected, change, now), do: {:ok, nil, c})

    if Code.ensure_loaded?(NativeBranchReleaseOps) do
      defp native_release(context, child, operation, arguments) do
        with {:ok, parent} <- Database.read(context, child.branch.source, :machine),
             do: apply(NativeBranchReleaseOps, operation, [parent, child | arguments])
      end
    else
      defp native_release(_context, _child, _operation, _arguments),
        do: {:error, %SmolBox.Error{category: :unsupported_capability, operation: :store}}
    end

    defp pair(context, key, guard, id, now) do
      with {:ok, p} <- Database.guarded_machine(context, key, guard, now),
           {:ok, c} <- Database.read(context, {elem(key, 0), id}, :machine),
           do: {:ok, p, c}
    end
  else
    def capabilities, do: %{}
  end
end
