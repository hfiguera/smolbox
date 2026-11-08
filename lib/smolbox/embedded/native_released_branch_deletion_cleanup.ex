defmodule SmolBox.Embedded.NativeReleasedBranchDeletionCleanup do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    NativeGrowth,
    NativeReleasedBranchDeletion,
    NativeReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionCleanup,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{ManagedMachine, Validation}
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  defp release(authority), do: NativeReleasedBranchDeletion.release(authority)
  def eligible?(child), do: NativeReleasedBranchDeletion.eligible?(child)

  def intent(authority, :cleanup, version, delete_version, receipt) do
    {:ok, release} = release(authority)
    completion = BranchCompletion.to_wire(authority.completion)

    digest =
      BranchCanonical.digest([
        "smolbox-native-released-delete-cleanup-v1",
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
      "operation_id" => "cleanup-delete-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", ReleasedBranchDeletionCleanup.request_digest(request))
  end

  def valid?(%__MODULE__{} = saved, authority, :cleanup) do
    with true <- Validation.struct_shape?(saved, __MODULE__),
         true <- version?(saved.version) and version?(saved.delete_version),
         true <- saved.delete_version <= saved.version,
         {:ok, _} <- release(authority),
         true <- ReleasedBranchDeletionCleanup.request?(saved.request),
         true <-
           saved.request ==
             intent(
               authority,
               :cleanup,
               saved.version,
               saved.delete_version,
               saved.request["child"]
             ),
         do: saved.proof == nil or matches?(saved, :cleanup, saved.proof),
         else: (_ -> false)
  end

  def valid?(_, _, _), do: false

  def matches?(
        %__MODULE__{request: request},
        :cleanup,
        %ReleasedBranchDeletionResolution{} = proof
      ),
      do: ReleasedBranchDeletionCleanup.matches?(proof, request)

  def matches?(_, _, _), do: false

  def record?(
        %{branch: %{native_authority: %{delete_cleanup: %__MODULE__{} = saved} = authority}} =
          child
      ) do
    with true <- valid?(saved, authority, :cleanup) and saved.version < child.version,
         true <- child.last_request == {:delete, saved.delete_version},
         {:ok, receipt, _, _} <- NativeGrowth.head(child),
         true <- receipt == saved.request["child"],
         do:
           if(saved.proof == nil,
             do: eligible?(child) or historical?(child),
             else: completed_state?(child)
           ),
         else: (_ -> false)
  end

  def record?(_), do: false

  defp completed_state?(child),
    do:
      child.state == :deleted and ManagedMachine.idle?(child) and child.reservation == nil and
        child.branch.state in [:ready, :released, :retired, :closed]

  def historical?(child),
    do: NativeReleasedBranchDeletionContinuation.historical?(child)

  def acknowledged?(
        %{delete_cleanup: %__MODULE__{proof: %ReleasedBranchDeletionResolution{}} = saved} =
          authority
      ),
      do: valid?(saved, authority, :cleanup) and matches?(saved, :cleanup, saved.proof)

  def acknowledged?(_), do: false

  def preserved?(nil, %__MODULE__{version: version, proof: nil}, version), do: true

  def preserved?(%__MODULE__{proof: nil} = saved, %__MODULE__{} = next, _),
    do: %{next | proof: nil} == saved

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)
end
