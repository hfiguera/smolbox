defmodule SmolBox.Runtime.BranchObservation do
  @moduledoc false
  alias SmolBox.Backend

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchChildAbsence,
    NativeBranchBacking,
    NativeBranchReleaseResult,
    NativeBranchResult,
    NativeBranchRetirement
  }

  alias SmolBox.Runtime.Target

  # One operational owner across both observations. Each reference carries only
  # its own saved record authority; source authority cannot stand in for a child.
  def resolution(worker, parent, %{branch: %{native_authority: authority}} = child, :keep)
      when not is_nil(authority) do
    worker = Target.pin(worker)

    with {:ok, result} <-
           Backend.branch_inspect_child(
             Target.connection(worker, parent),
             child,
             child.branch.spec.hold
           ),
         true <-
           is_struct(result, NativeBranchResult) or is_struct(result, NativeBranchReleaseResult),
         do: {:ok, [result.source, result]},
         else: (
           false ->
             {:error,
              %SmolBox.Error{
                category: :identity_conflict,
                operation: :branch,
                evidence: :dispatch_uncertain
              }}

           error ->
             error
         )
  end

  def resolution(worker, parent, child, disposition) when disposition in [:keep, :deleted] do
    worker = Target.pin(worker)

    with {:ok, source} <- source(worker, parent, disposition),
         {:ok, observed} <- child(worker, child, disposition),
         do: {:ok, [source, observed]}
  end

  def retirement(worker, %{branch: %{native_authority: authority}} = child)
      when not is_nil(authority) do
    worker = Target.pin(worker)

    with {:ok, request} <- NativeBranchRetirement.request(child),
         {:ok, %BranchChildAbsence{} = proof} <- absent(worker, child),
         true <- BranchChildAbsence.matches?(proof, request),
         do: {:ok, [proof]},
         else: (
           {:error, _} = error ->
             error

           _ ->
             {:error,
              %SmolBox.Error{
                category: :identity_conflict,
                operation: :branch,
                evidence: :dispatch_uncertain
              }}
         )
  end

  def retirement(worker, child) do
    worker = Target.pin(worker)
    with {:ok, :absent} <- absent(worker, child), do: {:ok, []}
  end

  def storage_release(worker, parent, %{branch: %{native_authority: authority}} = child)
      when not is_nil(authority) do
    worker = Target.pin(worker)

    owner = if NativeBranchBacking.unbooted?(child), do: parent, else: child

    with %NativeBranchBacking{request: request, proof: nil} <- authority.backing,
         {:ok, %BranchBackingRelease{} = proof} <-
           Backend.release_branch_backing(Target.connection(worker, owner), parent, child, true),
         true <- NativeBranchBacking.matches?(proof, request),
         do: {:ok, [proof]},
         else: (
           {:error, _} = error ->
             error

           _ ->
             {:error,
              %SmolBox.Error{
                category: :identity_conflict,
                operation: :branch,
                evidence: :dispatch_uncertain
              }}
         )
  end

  def storage_release(worker, parent, child) do
    worker = Target.pin(worker)

    with {:ok, :absent} <- absent(worker, parent),
         {:ok, :absent} <- absent(worker, child),
         do: {:ok, []}
  end

  defp absent(worker, record),
    do: Backend.branch_absent(Target.connection(worker, record), record.machine_name)

  defp source(worker, parent, disposition) do
    case Backend.inspect_machine(Target.connection(worker, parent), parent.machine_name) do
      {:error, %{category: :not_found}} when disposition == :deleted -> {:ok, :absent}
      result -> result
    end
  end

  defp child(worker, child, :keep),
    do:
      Backend.branch_inspect_child(
        Target.connection(worker, child),
        child,
        child.branch.spec.hold
      )

  defp child(worker, child, :deleted), do: absent(worker, child)
end
