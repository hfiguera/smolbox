defmodule SmolBox.Embedded.NativeBranchDeletionCollection do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchDeletionCollection,
    NativeBranchDeletion,
    NativeBranchDeletionState,
    NativeReleasedBranchDeletion
  }

  alias SmolBox.Validation
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  def eligible?(child), do: NativeBranchDeletion.resolvable?(child)

  def intent(authority, :collect, version, delete_version, receipt) do
    completion = BranchCompletion.to_wire(authority.completion)

    release =
      case NativeReleasedBranchDeletion.release(authority) do
        {:ok, release} -> release
        :error -> nil
      end

    digest =
      BranchCanonical.digest([
        "smolbox-native-original-delete-collection-v1",
        authority.fingerprint,
        version,
        delete_version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(completion, :completion),
        if(release, do: BranchCanonical.ordered(release, :child_release), else: nil)
      ])

    request = %{
      "completion" => completion,
      "child" => receipt,
      "operation_id" => "collect-delete-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    request = if release, do: Map.put(request, "release", release), else: request
    Map.put(request, "request_sha256", BranchDeletionCollection.request_digest(request))
  end

  def valid?(%__MODULE__{} = saved, %{completion: %BranchCompletion{}} = authority, :collect),
    do:
      Validation.struct_shape?(saved, __MODULE__) and version?(saved.version) and
        version?(saved.delete_version) and saved.delete_version <= saved.version and
        BranchDeletionCollection.request?(saved.request) and
        saved.request ==
          intent(authority, :collect, saved.version, saved.delete_version, saved.request["child"]) and
        (saved.proof == nil or matches?(saved, :collect, saved.proof))

  def valid?(_, _, _), do: false

  def matches?(%__MODULE__{request: request}, :collect, %BranchDeletionCollection{} = proof),
    do: BranchDeletionCollection.matches?(proof, request)

  def matches?(_, _, _), do: false

  def record?(
        %{branch: %{native_authority: %{delete_collection: %__MODULE__{} = saved} = authority}} =
          child,
        historical?
      ),
      do:
        valid?(saved, authority, :collect) and
          NativeBranchDeletionState.bound_record?(child, saved) and
          (eligible?(child) or historical?.(child, :held) or historical?.(child, :released))

  def record?(_, _), do: false

  def preserved?(before, after_record, version),
    do: NativeBranchDeletionState.preserves?(before, after_record, version, __MODULE__)

  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)
end
