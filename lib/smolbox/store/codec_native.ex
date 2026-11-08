defmodule SmolBox.Store.CodecNative do
  @moduledoc false
  alias SmolBox.Store.CodecFields

  @defaults %{
    SmolBox.Execution => [backend_assignment: nil],
    SmolBox.ManagedMachine => [backend_assignment: nil],
    SmolBox.Machine => [backend_identity: nil]
  }
  def required?(%{backend_assignment: assignment}) when not is_nil(assignment), do: true
  def required?(_record), do: false
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)
  def payload(record), do: record |> strip() |> :erlang.term_to_binary()

  def legacy_term(payload) do
    {record, used} = :erlang.binary_to_term(payload, [:safe, :used])
    {upgrade(record), used}
  end
end
