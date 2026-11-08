defmodule SmolBox.Store.CodecNativeBranchDeletionActions do
  @moduledoc false
  alias SmolBox.Embedded.NativeBranchAuthority
  alias SmolBox.Store.{CodecFields, CodecNativePreparedBranchRetirements}
  @defaults %{NativeBranchAuthority => [delete_continuation: nil, delete_cleanup: nil]}
  def strip(record),
    do:
      record
      |> CodecNativePreparedBranchRetirements.strip()
      |> CodecFields.transform(@defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecFields.transform(@defaults, :upgrade)
    |> CodecNativePreparedBranchRetirements.upgrade()
  end

  def required?(%{
        backend_assignment: %{version: 2},
        branch: %{native_authority: %{} = authority}
      }),
      do:
        Map.get(authority, :delete_continuation) != nil or
          Map.get(authority, :delete_cleanup) != nil

  def required?(_), do: false
end
