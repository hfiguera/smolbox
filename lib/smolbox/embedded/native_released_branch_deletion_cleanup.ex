defmodule SmolBox.Embedded.NativeReleasedBranchDeletionCleanup do
  @moduledoc false
  alias SmolBox.Embedded.{
    NativeBranchDeletionState,
    NativeReleasedBranchDeletion,
    ReleasedBranchDeletionCleanup,
    ReleasedBranchDeletionResolution
  }

  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  @operation {ReleasedBranchDeletionCleanup, "cleanup-delete-",
              "smolbox-native-released-delete-cleanup-v1"}

  defdelegate eligible?(child), to: NativeReleasedBranchDeletion

  def intent(authority, :cleanup, version, delete_version, receipt),
    do:
      NativeReleasedBranchDeletion.request(
        authority,
        version,
        delete_version,
        receipt,
        @operation
      )

  def valid?(%__MODULE__{} = saved, authority, :cleanup),
    do:
      NativeReleasedBranchDeletion.valid_request?(saved, authority, __MODULE__, @operation) and
        (saved.proof == nil or matches?(saved, :cleanup, saved.proof))

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
          child,
        historical?
      ),
      do:
        valid?(saved, authority, :cleanup) and
          NativeReleasedBranchDeletion.bound_record?(child, saved, historical?)

  def record?(_, _), do: false

  def acknowledged?(
        %{delete_cleanup: %__MODULE__{proof: %ReleasedBranchDeletionResolution{}} = saved} =
          authority
      ),
      do: valid?(saved, authority, :cleanup) and matches?(saved, :cleanup, saved.proof)

  def acknowledged?(_), do: false

  def preserved?(before, after_record, version),
    do: NativeBranchDeletionState.preserves?(before, after_record, version, __MODULE__)
end
