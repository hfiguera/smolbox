defmodule SmolBox.Store.CodecKubernetes do
  @moduledoc false
  alias SmolBox.{Error, Execution}
  alias SmolBox.Kubernetes.ExecutionPolicy
  alias SmolBox.Store.CodecFields

  @prefix "smolbox-record-v54\0"
  @max_bytes 16_777_216
  @defaults %{
    Execution => [backend_receipt: nil, backend_cleanup: nil, backend_create_state: nil]
  }
  @modules [
    Execution,
    SmolBox.ExecutionSpec,
    SmolBox.Command,
    SmolBox.Profile,
    SmolBox.Result,
    SmolBox.Error,
    SmolBox.Machine,
    SmolBox.Kubernetes.Assignment,
    SmolBox.Kubernetes.Binding,
    SmolBox.Kubernetes.Receipt,
    SmolBox.Kubernetes.Identity,
    SmolBox.Kubernetes.Observation,
    SmolBox.Kubernetes.CleanupProof
  ]

  def required?(record), do: ExecutionPolicy.required?(record)
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)

  def upgrade(record) do
    if required?(record), do: raise(ArgumentError)
    CodecFields.transform(record, @defaults, :upgrade)
  end

  def legacy_payload(record), do: record |> strip() |> :erlang.term_to_binary()

  def legacy_term(payload) do
    {record, used} = :erlang.binary_to_term(payload, [:safe, :used])
    {upgrade(record), used}
  end

  def encode(%Execution{} = record) do
    with true <- required?(record),
         :ok <- Execution.validate(record),
         bytes = @prefix <> :erlang.term_to_binary(record),
         true <- byte_size(bytes) <= @max_bytes,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  def decode(<<@prefix, 131, tag, _::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    Enum.each(@modules, &Code.ensure_loaded!/1)
    <<@prefix, payload::binary>> = bytes

    with {%Execution{} = record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and required?(record),
         :ok <- Execution.validate(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  def decode(_), do: invalid()
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
