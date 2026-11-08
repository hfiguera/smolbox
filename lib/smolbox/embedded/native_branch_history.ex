defmodule SmolBox.Embedded.NativeBranchHistory do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCreation,
    BranchPublication,
    NativeBranchAuthority,
    NativePreparedBranchRetirement
  }

  alias SmolBox.Validation

  def record?(%{backend_assignment: nil} = record),
    do:
      Map.get(record, :native_branch_history, %{}) == %{} and
        (Map.get(record, :branch) == nil or
           match?(%SmolBox.Branch{native_authority: nil}, Map.get(record, :branch)))

  def record?(%{backend_assignment: %{version: 2}, branch: %{}} = record),
    do: record.native_branch_history == %{} and NativeBranchAuthority.child?(record)

  def record?(%{backend_assignment: %{version: 2}, branch: nil} = record),
    do: source?(record)

  def record?(%{backend_assignment: %{version: 2}} = record),
    do:
      not BranchCreation.valid?(record.backend_assignment.creation) or
        (Map.get(record, :managed_machine) != nil and BranchCreation.command?(record))

  def record?(record),
    do:
      Map.get(record, :native_branch_history, %{}) == %{} and
        Map.get(record, :branch_children, %{}) == %{} and Map.get(record, :branch) == nil and
        Map.get(record, :active_branch) == nil

  def transitions(record) do
    history = Map.get(record, :native_branch_history, %{})

    if is_map(history) and map_size(history) <= 256 and
         Enum.all?(history, fn {id, proof} -> entry?(record, id, proof) end),
       do: {:ok, history |> Map.values() |> Enum.filter(&is_struct(&1, BranchPublication))},
       else: :error
  rescue
    _ -> :error
  end

  defp source?(record) do
    with true <- is_map(record.branch_children) and map_size(record.branch_children) <= 256,
         {:ok, history} <- transitions(record),
         true <- history == [] or record.spec.checkpointable do
      Enum.all?(record.branch_children, fn {id, retired} ->
        is_boolean(retired) and
          (retired or id == record.active_branch or Map.has_key?(record.native_branch_history, id))
      end) and
        (record.branch_children == %{} or
           source_features?(record.spec))
    else
      _ -> false
    end
  end

  defp source_features?(spec),
    do:
      spec.checkpointable and spec.profile.network == :offline and
        spec.ports == [] and spec.volumes == [] and spec.workload == nil

  defp entry?(record, id, %NativePreparedBranchRetirement{} = saved),
    do: NativePreparedBranchRetirement.source?(record, id, saved)

  defp entry?(record, id, %BranchPublication{} = proof) do
    profile = record.spec.profile
    intent = proof.change["child_origin"]["intent"]
    child = intent["plan"]["ordinary_child"]

    Validation.identifier?(id) and Map.has_key?(record.branch_children, id) and
      BranchPublication.valid?(proof) and intent["child"]["operation_id"] == id and
      BranchCanonical.origin(proof.previous) ==
        BranchCanonical.origin(record.created_machine.backend_identity.receipt) and
      intent["approval"]["host_overhead_mb"] == profile.host_overhead_mb and
      child["cpus"] == profile.cpus and
      child["memory_mb"] == profile.memory_mb + profile.host_overhead_mb
  end

  defp entry?(_, _, _), do: false
end
