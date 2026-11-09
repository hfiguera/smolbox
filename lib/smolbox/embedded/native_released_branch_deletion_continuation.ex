defmodule SmolBox.Embedded.NativeReleasedBranchDeletionContinuation do
  @moduledoc false
  alias SmolBox.Embedded.{
    NativeBranchDeletionState,
    NativeReleasedBranchDeletion,
    ReleasedBranchDeletionContinuation
  }

  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  @operation {ReleasedBranchDeletionContinuation, "continue-delete-",
              "smolbox-native-released-delete-continuation-v1"}

  defdelegate eligible?(child), to: NativeReleasedBranchDeletion

  def intent(authority, :continue, version, delete_version, receipt),
    do:
      NativeReleasedBranchDeletion.request(
        authority,
        version,
        delete_version,
        receipt,
        @operation
      )

  def valid?(%__MODULE__{} = saved, authority, :continue),
    do:
      NativeReleasedBranchDeletion.valid_request?(saved, authority, __MODULE__, @operation) and
        (saved.proof == nil or matches?(saved, :continue, saved.proof))

  def valid?(_, _, _), do: false

  def matches?(
        %__MODULE__{request: request},
        :continue,
        %ReleasedBranchDeletionContinuation{} = proof
      ),
      do: ReleasedBranchDeletionContinuation.matches?(proof, request)

  def matches?(_, _, _), do: false

  def record?(
        %{branch: %{native_authority: %{delete_continuation: %__MODULE__{} = saved} = authority}} =
          child,
        historical?
      ),
      do:
        valid?(saved, authority, :continue) and
          NativeReleasedBranchDeletion.bound_record?(child, saved, historical?)

  def record?(_, _), do: false

  def acknowledged?(
        %{delete_continuation: %__MODULE__{proof: %ReleasedBranchDeletionContinuation{}} = saved} =
          authority
      ),
      do: valid?(saved, authority, :continue) and matches?(saved, :continue, saved.proof)

  def acknowledged?(_), do: false

  def preserved?(before, after_record, version),
    do: NativeBranchDeletionState.preserves?(before, after_record, version, __MODULE__)
end
