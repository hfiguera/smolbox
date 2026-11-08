defmodule SmolBox.Store.CodecNativeBranchAuthority do
  @moduledoc false
  alias SmolBox.Store.{CodecFields, CodecNativeBranchReleases}

  @defaults %{
    SmolBox.ManagedMachine => [native_branch_history: %{}],
    SmolBox.Branch => [native_authority: nil]
  }

  def reader, do: 1

  def strip(record),
    do: record |> CodecNativeBranchReleases.strip() |> CodecFields.transform(@defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    record |> CodecFields.transform(@defaults, :upgrade) |> CodecNativeBranchReleases.upgrade()
  end

  def required?(%{backend_assignment: %{version: 2, creation: creation}} = record)
      when is_map(creation),
      do:
        Map.has_key?(creation, "branch") or
          Map.get(record, :native_branch_history, %{}) != %{} or
          Map.get(record, :branch_children, %{}) != %{} or
          match?(%{native_authority: authority} when authority != nil, Map.get(record, :branch))

  def required?(_), do: false
end
