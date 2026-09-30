defmodule SmolBox.Store.CodecSources do
  @moduledoc false
  alias SmolBox.{ManagedMachine, Source}
  alias SmolBox.Store.CodecBranches
  alias SmolBox.Store.CodecCaptures
  alias SmolBox.Store.CodecExpansion
  alias SmolBox.Store.CodecExports

  def required?(%{spec: %{command: %SmolBox.ImagePull{}}}), do: true

  def required?(%{spec: %{artifact: artifact}}), do: Source.remote?(artifact)
  def required?(_record), do: false

  def strip(%ManagedMachine{preparation: nil} = record), do: Map.delete(record, :preparation)
  def strip(record), do: record

  def legacy_term(payload) do
    {record, used} = :erlang.binary_to_term(payload, [:safe, :used])
    if required?(record), do: raise(ArgumentError)

    {CodecExpansion.upgrade(
       CodecBranches.upgrade(CodecCaptures.upgrade(CodecExports.upgrade(upgrade(record))))
     ), used}
  end

  defp upgrade(%ManagedMachine{} = record) do
    if Map.has_key?(record, :preparation), do: raise(ArgumentError)
    Map.put(record, :preparation, nil)
  end

  defp upgrade(record), do: record
end
