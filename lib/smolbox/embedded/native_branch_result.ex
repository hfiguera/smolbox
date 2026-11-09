defmodule SmolBox.Embedded.NativeBranchResult do
  @moduledoc """
  Native branch completion paired with fresh source and child observations.

  Custom stores consume this transient result in an atomic branch transaction.
  The original completion alone cannot prove either machine is currently running.
  Validate its binding against the frozen request and original process identities;
  preserve the immutable child root and source material history separately.
  Inspect output omits receipt and ownership fields. This type grants no SDK
  manager enrollment and does not enable native branch admission.
  """
  alias SmolBox.Embedded.{BranchCompletion, Identity, NativeBranchAuthority}
  alias SmolBox.{Machine, ManagedMachine, Validation}

  @enforce_keys [:completion, :source, :child]
  @derive {Inspect, only: []}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          completion: BranchCompletion.t(),
          source: Machine.t(),
          child: Machine.t()
        }

  @doc false
  def valid?(%__MODULE__{} = result),
    do:
      Validation.struct_shape?(result, __MODULE__) and
        BranchCompletion.valid?(result.completion) and
        running?(result.source) and running?(result.child)

  def valid?(_), do: false

  @doc false
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
