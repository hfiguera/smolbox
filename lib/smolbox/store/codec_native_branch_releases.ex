defmodule SmolBox.Store.CodecNativeBranchReleases do
  @moduledoc false
  alias SmolBox.Embedded.{BranchReleaseTransition, NativeBranchAuthority}
  alias SmolBox.Store.{CodecFields, CodecNativeBranchRetirements}
  @defaults %{NativeBranchAuthority => [release: nil]}
  def strip(record),
    do: record |> CodecNativeBranchRetirements.strip() |> CodecFields.transform(@defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    record |> CodecFields.transform(@defaults, :upgrade) |> CodecNativeBranchRetirements.upgrade()
  end

  def required?(%{backend_assignment: %{version: 2}} = record),
    do:
      match?(
        %{native_authority: %{release: release}} when not is_nil(release),
        Map.get(record, :branch)
      ) or
        Enum.any?(
          [Map.get(record, :created_machine), Map.get(record, :observed_machine)],
          &explicit?/1
        )

  def required?(_), do: false

  defp explicit?(%{
         backend_identity: %{
           transition: %BranchReleaseTransition{change: %{"mode" => "explicit"}}
         }
       }),
       do: true

  defp explicit?(_), do: false
end
