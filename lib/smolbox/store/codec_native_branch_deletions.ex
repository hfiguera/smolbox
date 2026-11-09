defmodule SmolBox.Store.CodecNativeBranchDeletions do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativeBranchDeletionActions}
  @defaults %{NativeBranchAuthority => [deletion: nil]}
  def strip(record),
    do:
      record
      |> CodecNativeBranchDeletionActions.strip()
      |> CodecFields.transform(@defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecFields.transform(@defaults, :upgrade)
    |> CodecNativeBranchDeletionActions.upgrade()
  end

  def required?(%{
        backend_assignment: %{version: 2},
        branch: %{native_authority: %{deletion: saved}}
      }),
      do: saved != nil

  def required?(_), do: false
end
