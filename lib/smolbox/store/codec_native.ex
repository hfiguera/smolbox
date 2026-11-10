defmodule SmolBox.Store.CodecNative do
  @moduledoc false
  alias SmolBox.Store.{
    CodecBranches,
    CodecFields,
    CodecMaterial,
    CodecNativeCaptures,
    CodecNativeMounts,
    CodecNativeVolumes,
    CodecStaticBranchEgress
  }

  @defaults %{
    SmolBox.Execution => [backend_assignment: nil],
    SmolBox.ManagedMachine => [backend_assignment: nil],
    SmolBox.Machine => [backend_identity: nil]
  }
  def required?(%{backend_assignment: assignment}) when not is_nil(assignment), do: true
  def required?(_record), do: false

  def strip(record),
    do:
      record
      |> CodecNativeMounts.strip()
      |> CodecNativeVolumes.strip()
      |> CodecMaterial.strip()
      |> CodecStaticBranchEgress.strip()
      |> CodecFields.transform(@defaults, :strip)

  def upgrade(record),
    do: record |> CodecFields.transform(@defaults, :upgrade) |> CodecStaticBranchEgress.upgrade()

  def payload(record),
    do:
      record
      |> strip()
      |> CodecNativeCaptures.strip()
      |> CodecBranches.strip_release_env()
      |> :erlang.term_to_binary()

  def legacy_term(payload) do
    {record, used} = :erlang.binary_to_term(payload, [:safe, :used])

    {record
     |> CodecNativeMounts.upgrade()
     |> CodecNativeVolumes.upgrade()
     |> CodecMaterial.upgrade()
     |> upgrade()
     |> CodecNativeCaptures.upgrade()
     |> CodecBranches.upgrade_release_env(), used}
  end
end
