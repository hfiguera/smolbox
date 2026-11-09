defmodule SmolBox.Store.CodecNativeReleasedBranchDeletions do
  @moduledoc false
  alias SmolBox.Embedded.NativeReleasedBranchDeletion

  def required?(%{branch: %{native_authority: %{deletion: %NativeReleasedBranchDeletion{}}}}),
    do: true

  def required?(_), do: false
end
