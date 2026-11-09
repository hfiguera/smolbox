defmodule SmolBox.Store.NativeBranchBackingOps do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAdmission

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    NativeBranchBacking,
    NativeGrowth
  }

  alias SmolBox.{Error, ManagedMachine, Validation}

  def accept(parent, child, version, true, now) do
    with :ok <- pair(parent, child, now),
         true <- child.version == version do
      case child.branch.native_authority.backing do
        %NativeBranchBacking{} -> {:ok, parent, child}
        nil -> accept_new(parent, child, now)
      end
    else
      _ -> error()
    end
  end

  def accept(_, _, _, _, _), do: error()

  defp accept_new(parent, %{branch: %{state: :retired}} = child, now) do
    with {:ok, source, _, _} <- NativeGrowth.head(parent),
         {:ok, receipt} <- NativeBranchBacking.child_receipt(child),
         authority = child.branch.native_authority,
         request = NativeBranchBacking.intent(authority, child.version, source, receipt),
         saved = %NativeBranchBacking{version: child.version, request: request},
         {:ok, child} <-
           update(
             child,
             %{authority | backing: saved},
             NativeBranchBacking.pending_state(child),
             now
           ),
         {:ok, parent} <- ManagedMachine.update(parent, %{}, now),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp accept_new(_, _, _), do: error()

  def complete(parent, child, %BranchBackingRelease{} = proof, now) do
    with :ok <- pair(parent, child, now),
         %NativeBranchBacking{} = saved <- child.branch.native_authority.backing,
         {:ok, source, _, _} <- NativeGrowth.head(parent),
         true <-
           source == saved.request["source"] and
             NativeBranchBacking.matches?(proof, saved.request) do
      case saved.proof do
        ^proof -> {:ok, parent, child}
        nil -> close(parent, child, saved, proof, now)
        _ -> error()
      end
    else
      _ -> error()
    end
  end

  def complete(_, _, _, _), do: error()

  defp close(parent, child, saved, proof, now) do
    authority = %{child.branch.native_authority | backing: %{saved | proof: proof}}

    with {:ok, child} <- update(child, authority, :closed, now),
         {:ok, parent} <- ManagedMachine.update(parent, %{}, now),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp update(child, authority, state, now),
    do:
      ManagedMachine.update(
        child,
        %{branch: %{child.branch | native_authority: authority, state: state}},
        now
      )

  defp pair(parent, child, now),
    do:
      if(Validation.timestamp?(now) and NativeBranchAdmission.backing_pair?(parent, child),
        do: :ok,
        else: error()
      )

  defp error, do: {:error, %Error{category: :identity_conflict, operation: :branch}}
end
