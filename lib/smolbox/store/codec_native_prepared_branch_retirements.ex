defmodule SmolBox.Store.CodecNativePreparedBranchRetirements do
  @moduledoc false
  alias SmolBox.Embedded.{NativeBranchAuthority, NativePreparedBranchRetirement}
  alias SmolBox.Store.{CodecFields, CodecNativeUnbootedBranchDisposals}
  @defaults %{NativeBranchAuthority => [prepared_retirement: nil]}

  def strip(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecNativeUnbootedBranchDisposals.strip()
    |> CodecFields.transform(@defaults, :strip)
  end

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)

    record
    |> CodecFields.transform(@defaults, :upgrade)
    |> CodecNativeUnbootedBranchDisposals.upgrade()
  end

  def required?(record) when is_map(record),
    do:
      match?(
        %{branch: %{native_authority: %{prepared_retirement: saved}}} when not is_nil(saved),
        record
      ) or
        Enum.any?(history(record), fn {_, value} ->
          is_struct(value, NativePreparedBranchRetirement)
        end)

  def required?(_), do: false

  defp history(record) do
    case Map.get(record, :native_branch_history, %{}) do
      value when is_map(value) -> value
      _ -> raise ArgumentError
    end
  end
end
