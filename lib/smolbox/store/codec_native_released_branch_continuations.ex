defmodule SmolBox.Store.CodecNativeReleasedBranchContinuations do
  @moduledoc false
  alias SmolBox.Embedded.NativeReleasedBranchDeletionContinuation

  def required?(%{
        branch: %{
          native_authority: %{delete_continuation: %NativeReleasedBranchDeletionContinuation{}}
        }
      }),
      do: true

  def required?(_), do: false
end
