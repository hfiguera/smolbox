defmodule SmolBox.Embedded.NativeReleasedBranchDeletion do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    NativeBranchDeletion,
    NativeBranchRelease,
    NativeGrowth,
    NativeReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{ManagedMachine, Validation}
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  def release(%{release: %NativeBranchRelease{transition: %BranchReleaseTransition{} = proof}}),
    do: {:ok, BranchReleaseTransition.to_wire(proof)}

  def release(%{release: nil, completion: %BranchCompletion{held: false, release: proof}})
      when is_map(proof),
      do: {:ok, proof}

  def release(_), do: :error

  def eligible?(%{branch: %{state: state, native_authority: authority}} = child) do
    NativeBranchDeletion.required?(child) and state in [:ready, :released] and
      inactive?(child) and
      match?({:delete, version} when is_integer(version) and version > 0, child.last_request) and
      authority.retirement == nil and authority.backing == nil and
      match?({:ok, _}, release(authority))
  end

  def eligible?(_), do: false

  defp inactive?(child),
    do:
      child.active_execution == nil and child.active_branch == nil and
        child.active_expansion == nil and child.active_capture == nil and
        child.active_export == nil

  def intent(authority, version, delete_version, receipt) do
    {:ok, release} = release(authority)
    completion = BranchCompletion.to_wire(authority.completion)

    digest =
      BranchCanonical.digest([
        "smolbox-native-released-delete-resolution-v1",
        authority.fingerprint,
        version,
        delete_version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(completion, :completion),
        BranchCanonical.ordered(release, :child_release)
      ])

    request = %{
      "completion" => completion,
      "release" => release,
      "child" => receipt,
      "operation_id" => "resolve-delete-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", ReleasedBranchDeletionResolution.request_digest(request))
  end

  def valid?(%__MODULE__{} = saved, authority) do
    with true <- Validation.struct_shape?(saved, __MODULE__),
         true <- version?(saved.version) and version?(saved.delete_version),
         true <- saved.delete_version <= saved.version,
         {:ok, _} <- release(authority),
         true <- ReleasedBranchDeletionResolution.request?(saved.request),
         true <-
           saved.request ==
             intent(authority, saved.version, saved.delete_version, saved.request["child"]),
         do: saved.proof == nil or matches?(saved, saved.proof),
         else: (_ -> false)
  end

  def valid?(_, _), do: false

  def matches?(%__MODULE__{request: request}, %ReleasedBranchDeletionResolution{} = proof),
    do: ReleasedBranchDeletionResolution.matches?(proof, request)

  def matches?(_, _), do: false

  def record?(
        %{branch: %{native_authority: %{deletion: %__MODULE__{} = saved} = authority}} = child
      ) do
    with true <- valid?(saved, authority) and saved.version < child.version,
         true <- child.last_request == {:delete, saved.delete_version},
         {:ok, receipt, _, _} <- NativeGrowth.head(child),
         true <- receipt == saved.request["child"],
         do:
           if(saved.proof == nil,
             do: eligible?(child) or NativeReleasedBranchDeletionContinuation.historical?(child),
             else: completed_state?(child)
           ),
         else: (_ -> false)
  end

  def record?(_), do: false

  defp completed_state?(child),
    do:
      child.state == :deleted and ManagedMachine.idle?(child) and child.reservation == nil and
        child.branch.state in [:ready, :released, :retired, :closed]

  def preserved?(nil, %__MODULE__{version: version, proof: nil}, version), do: true

  def preserved?(%__MODULE__{proof: nil} = saved, %__MODULE__{} = next, _),
    do: %{next | proof: nil} == saved

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)
end
