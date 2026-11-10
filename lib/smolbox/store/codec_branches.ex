defmodule SmolBox.Store.CodecBranches do
  @moduledoc false
  alias SmolBox.ManagedMachine

  def required?(%ManagedMachine{branch: branch, branch_children: children}),
    do: branch != nil or children != %{}

  def required?(_), do: false

  def strip_release_env(%{branch: %SmolBox.Branch{release_env: []} = branch} = record),
    do: %{record | branch: Map.delete(branch, :release_env)}

  def strip_release_env(record), do: record

  def upgrade_release_env(%{branch: %SmolBox.Branch{} = branch} = record) do
    if Map.has_key?(branch, :release_env), do: raise(ArgumentError)
    %{record | branch: Map.put(branch, :release_env, [])}
  end

  def upgrade_release_env(record), do: record

  def strip(%ManagedMachine{branch: nil, branch_children: children, active_branch: nil} = m)
      when map_size(children) == 0,
      do: Map.drop(m, [:branch, :branch_children, :active_branch])

  def strip(record), do: record

  def upgrade(%ManagedMachine{} = record) do
    if Enum.any?([:branch, :branch_children, :active_branch], &Map.has_key?(record, &1)),
      do: raise(ArgumentError)

    record
    |> Map.put(:branch, nil)
    |> Map.put(:branch_children, %{})
    |> Map.put(:active_branch, nil)
  end

  def upgrade(record), do: record
end
