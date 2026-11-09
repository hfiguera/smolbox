defmodule SmolBox.Embedded.NativeBranchReleaseResult do
  @moduledoc """
  Explicit native held-release proof with current source and child observations.

  A custom store must bind this transient result to the original versioned release
  request, current source head and both original process identities before updating
  the pair. Completion and explicit resolution preserve all backing charges and
  the original creation completion. Inspect output omits native authority. This
  type alone enables neither release dispatch nor SDK manager enrollment.
  """
  alias SmolBox.Embedded.{Identity, NativeBranchRelease}
  alias SmolBox.{Machine, Validation}
  @enforce_keys [:transition, :source, :child]
  @derive {Inspect, only: []}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @doc false
  def bound?(%__MODULE__{} = result, authority) do
    release = authority.release

    Validation.struct_shape?(result, __MODULE__) and
      NativeBranchRelease.valid?(release, authority) and
      NativeBranchRelease.bound?(result.transition, release, authority) and
      observed?(result.source, release.source, release.source_pid) and
      observed?(result.child, result.transition.receipt, release.child_pid)
  end

  def bound?(_, _), do: false

  defp observed?(
         %Machine{state: :running, backend_identity: %Identity{} = identity},
         receipt,
         pid
       ),
       do:
         Identity.valid?(identity) and identity.receipt == receipt and
           identity.pid_identity == pid

  defp observed?(_, _, _), do: false
end
