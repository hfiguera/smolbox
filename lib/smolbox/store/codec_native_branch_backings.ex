defmodule SmolBox.Store.CodecNativeBranchBackings do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativeBranchDeletions}
  @defaults %{NativeBranchAuthority => [backing: nil]}
  def strip(record),
    do: record |> CodecNativeBranchDeletions.strip() |> CodecFields.transform(@defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    record |> CodecFields.transform(@defaults, :upgrade) |> CodecNativeBranchDeletions.upgrade()
  end

  def required?(%{
        backend_assignment: %{version: 2},
        branch: %{native_authority: %{backing: saved}}
      }),
      do: saved != nil

  def required?(_), do: false
end
