defmodule SmolBox.Embedded.NativeBranchDeletionState do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCompletion, NativeGrowth}
  alias SmolBox.{ManagedMachine, ManagedMachineState}

  def required?(%{
        __struct__: ManagedMachine,
        branch: %{
          native_authority: %{completion: %BranchCompletion{}}
        },
        operation: :delete,
        state: state
      }),
      do: state in [:unknown, :missing, :conflict]

  def required?(_), do: false

  def pending?(record) do
    required?(record) and inactive?(record) and
      match?({:delete, version} when is_integer(version) and version > 0, record.last_request) and
      record.branch.native_authority.retirement == nil and
      record.branch.native_authority.backing == nil
  end

  defp inactive?(record),
    do:
      record.active_execution == nil and record.active_branch == nil and
        record.active_expansion == nil and
        record.active_capture == nil and record.active_export == nil

  def completed?(child, states),
    do:
      child.state == :deleted and ManagedMachineState.idle?(child) and child.reservation == nil and
        child.branch.state in states

  def bound_record?(child, saved) do
    with true <- saved.version < child.version,
         true <- child.last_request == {:delete, saved.delete_version},
         {:ok, receipt, _, _} <- NativeGrowth.head(child),
         do: receipt == saved.request["child"],
         else: (_ -> false)
  end

  def preserves?(before, %{__struct__: module} = after_record, version, module) do
    case before do
      nil -> after_record.version == version and after_record.proof == nil
      %{__struct__: ^module, proof: nil} -> %{after_record | proof: nil} == before
      _ -> after_record == before
    end
  end

  def preserves?(_, _, _, _), do: false
end
