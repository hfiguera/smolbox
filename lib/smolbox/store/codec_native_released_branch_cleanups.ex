defmodule SmolBox.Store.CodecNativeReleasedBranchCleanups do
  @moduledoc false
  alias SmolBox.Embedded.NativeReleasedBranchDeletionCleanup

  def required?(%{
        branch: %{
          native_authority: %{delete_cleanup: %NativeReleasedBranchDeletionCleanup{}}
        }
      }),
      do: true

  def required?(_), do: false
end
