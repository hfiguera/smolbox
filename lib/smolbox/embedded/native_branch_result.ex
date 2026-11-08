defmodule SmolBox.Embedded.NativeBranchResult do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCompletion, Identity, NativeBranchAuthority}
  alias SmolBox.{Machine, ManagedMachine, Validation}

  # Historical completion is separate from the two positive current observations.
  # This ephemeral transaction input is never persisted or used as SDK authority.
  @enforce_keys [:completion, :source, :child]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          completion: BranchCompletion.t(),
          source: Machine.t(),
          child: Machine.t()
        }

  def valid?(%__MODULE__{} = result),
    do:
      Validation.struct_shape?(result, __MODULE__) and
        BranchCompletion.valid?(result.completion) and
        running?(result.source) and running?(result.child)

  def valid?(_), do: false

  def bound?(
        %__MODULE__{} = result,
        parent,
        %{branch: %{native_authority: %NativeBranchAuthority{} = authority}} = child
      ) do
    valid?(result) and NativeBranchAuthority.valid?(authority) and
      authority.source == ManagedMachine.key(parent) and
      authority.fingerprint == child.fingerprint and
      BranchCompletion.matches?(BranchCompletion.to_wire(result.completion), authority.request) and
      result.source.backend_identity.receipt == result.completion.publication["receipt"] and
      result.child.backend_identity.receipt == result.completion.child and
      source_pid?(result, child) and
      hd(result.source.backend_identity.pid_identity) !=
        hd(result.child.backend_identity.pid_identity)
  end

  def bound?(_, _, _), do: false

  defp source_pid?(result, child),
    do:
      result.source.backend_identity.pid_identity ==
        child.branch.source_machine.backend_identity.pid_identity and
        result.source.backend_identity.pid_identity ==
          result.completion.publication["change"]["child_origin"]["intent"]["source_pid"]

  defp running?(%Machine{state: :running, backend_identity: %Identity{} = identity}),
    do: Identity.valid?(identity) and identity.pid_identity != nil

  defp running?(_), do: false
end
