defmodule SmolBox.Embedded.NativeBranchAdmission do
  @moduledoc false
  alias SmolBox.ManagedMachine

  alias SmolBox.Embedded.{
    NativeBranchBacking,
    NativeBranchRetirement,
    NativeCollectedBranchPublication,
    NativePartialBranchCollection,
    NativePartialBranchDisposal,
    NativeUnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  def prepared_child?(
        %ManagedMachine{
          branch: %{
            state: :unknown,
            native_authority: %{
              collected_publication: nil,
              completion: nil,
              prepared_retirement: nil,
              partial_collection: nil
            }
          },
          operation: :branch_child
        } = child
      ),
      do: ManagedMachine.validate(child) == :ok

  def prepared_child?(_), do: false

  def prepared_pending?(parent, child),
    do:
      ManagedMachine.validate(parent) == :ok and prepared_child?(child) and
        parent.active_branch == child.id and parent.operation == :branch and
        parent.branch_children[child.id] == false and
        not Map.has_key?(parent.native_branch_history, child.id) and
        parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        child.branch.source == ManagedMachine.key(parent)

  def disposal_pending?(parent, child),
    do: partial_pending?(parent, child, &NativeUnbootedBranchDisposal.eligible?/1)

  def collected_publication_pending?(parent, child),
    do: partial_pending?(parent, child, &NativeCollectedBranchPublication.eligible?/1)

  def partial_collection_pending?(parent, child),
    do: partial_pending?(parent, child, &NativePartialBranchCollection.eligible?/1)

  def partial_disposal_pending?(parent, child),
    do: partial_pending?(parent, child, &NativePartialBranchDisposal.eligible?/1)

  defp partial_pending?(parent, child, eligible?) do
    ManagedMachine.validate(parent) == :ok and ManagedMachine.validate(child) == :ok and
      eligible?.(child) and NativePartialBranchCollection.source_pending?(parent, child)
  end

  def retirement_pair?(parent, child) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- NativeBranchRetirement.eligible?(child),
         {:ok, publication} <- NativeBranchRetirement.publication(child.branch.native_authority) do
      child.branch.source == ManagedMachine.key(parent) and parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and parent.active_branch != child.id and
        Map.has_key?(parent.branch_children, child.id) and
        parent.native_branch_history[child.id] == publication
    else
      _ -> false
    end
  end

  def backing_pair?(parent, child) do
    with true <- retirement_pair?(parent, child),
         true <- NativeBranchBacking.origin?(child.branch.native_authority),
         true <- child.branch.state in [:retired, :backing_pending, :closed],
         %NativeBranchRetirement{} <- child.branch.native_authority.retirement do
      parent.state == :deleted and ManagedMachine.idle?(parent) and parent.reservation == nil and
        parent.active_branch == nil and parent.branch_children[child.id] == true and
        Enum.all?(parent.branch_children, fn {_, retired} -> retired == true end)
    else
      _ -> false
    end
  end

  # Selection evidence is transient and requires the original pinned helper and
  # still-locked source/child pair. It never completes or disposes the child.
  def disposal_candidate?(
        %UnbootedBranchDisposalCandidate{} = candidate,
        parent,
        child,
        epoch,
        platform
      ) do
    with true <- disposal_pending?(parent, child),
         true <- child.branch.native_authority.disposal == nil,
         true <-
           UnbootedBranchDisposalCandidate.matches?(
             candidate,
             child.branch.native_authority.request
           ) do
      intent = get_in(candidate.publication, ~w(change child_origin intent))

      NativeCollectedBranchPublication.publication_pending?(parent, child, candidate.publication) and
        intent["epoch"] == epoch and candidate.publication["change"]["platform"] == platform and
        intent["source_pid"] == child.branch.source_machine.backend_identity.pid_identity and
        NativeUnbootedBranchDisposal.plan?(candidate, child.spec.profile)
    else
      _ -> false
    end
  end

  def disposal_candidate?(_, _, _, _, _), do: false
end
