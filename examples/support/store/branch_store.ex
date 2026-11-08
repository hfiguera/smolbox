defmodule SmolBox.DurableHost.BranchStore do
  @moduledoc false
  if Code.ensure_loaded?(SmolBox.Store.BranchOps) do
    alias SmolBox.DurableHost.{Database, WorkerStore}
    alias SmolBox.Store.{BranchOps, NativeBranchReleaseOps}
    def capabilities, do: %{managed_branches: 1}

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

    def run(context, :branch_retire, [key, guard, id, proof, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           do: BranchOps.retire(p, c, proof, now)
    end

    def run(context, :branch_retire, [key, guard, id, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now), do: BranchOps.retire(p, c, now)
    end

    def run(context, :branch_backing_accept, [key, guard, id, version, removed, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           do: BranchOps.accept_backing(p, c, version, removed, now)
    end

    def run(context, :branch_release_storage, [key, guard, id, proof, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           do: BranchOps.release_storage(p, c, proof, now)
    end

    def run(context, :branch_release_storage, [key, guard, id, now]) do
      with {:ok, p, c} <- pair(context, key, guard, id, now),
           {:ok, c} <- BranchOps.release_storage(p, c, now),
           do: {:ok, nil, c}
    end

    def run(context, :branch_release, [key, version, now]) do
      with {:ok, c} <- Database.read(context, key, :machine),
           do: accept_release(context, c, version, now)
    end

    def run(context, :branch_release_advance, [key, guard, expected, change, now]) do
      with {:ok, c} <- Database.guarded_machine(context, key, guard, now),
           do: advance_release(context, c, expected, change, now)
    end

    defp accept_release(context, %{branch: %{native_authority: authority}} = c, version, now)
         when not is_nil(authority) do
      with {:ok, p} <- Database.read(context, c.branch.source, :machine),
           do: NativeBranchReleaseOps.accept(p, c, version, now)
    end

    defp accept_release(_context, c, version, now),
      do: with({:ok, c} <- BranchOps.release(c, version, now), do: {:ok, nil, c})

    defp advance_release(
           context,
           %{branch: %{native_authority: authority}} = c,
           expected,
           change,
           now
         )
         when not is_nil(authority) do
      with {:ok, p} <- Database.read(context, c.branch.source, :machine),
           do: NativeBranchReleaseOps.advance(p, c, expected, change, now)
    end

    defp advance_release(_context, c, expected, change, now),
      do: with({:ok, c} <- BranchOps.release_advance(c, expected, change, now), do: {:ok, nil, c})

    defp pair(context, key, guard, id, now) do
      with {:ok, p} <- Database.guarded_machine(context, key, guard, now),
           {:ok, c} <- Database.read(context, {elem(key, 0), id}, :machine),
           do: {:ok, p, c}
    end
  else
    def capabilities, do: %{}
  end
end
