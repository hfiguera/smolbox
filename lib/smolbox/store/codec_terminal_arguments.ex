defmodule SmolBox.Store.CodecTerminalArguments do
  @moduledoc false
  alias SmolBox.{Error, Execution}
  alias SmolBox.Store.CodecFields
  alias SmolBox.Terminal.Spec

  @prefix "smolbox-record-v55\0"
  @max_bytes 16_777_216
  @defaults %{Spec => [args: []]}

  def reader, do: 1
  def strip(record), do: CodecFields.transform(record, @defaults, :strip)
  def upgrade(record), do: CodecFields.transform(record, @defaults, :upgrade)

  # Preserve the exact existing HTTP/native envelope inside this selective
  # extension. Its native histories and enrolled authority keep their own codec.
  def encode(%Execution{spec: %{command: %Spec{args: [_ | _] = args}}} = record, encode) do
    with :ok <- Execution.validate(record),
         base = put_in(record.spec.command.args, []),
         {:ok, encoded} <- encode.(base),
         bytes = @prefix <> :erlang.term_to_binary({encoded, args}),
         true <- byte_size(bytes) <= @max_bytes,
         do: {:ok, bytes},
         else: (_ -> invalid())
  end

  def decode(<<@prefix, 131, tag, _::binary>> = bytes, decode)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    <<@prefix, payload::binary>> = bytes

    with {{encoded, [_ | _] = args}, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload) and is_binary(encoded),
         false <- String.starts_with?(encoded, @prefix),
         {:ok, %Execution{spec: %{command: %Spec{args: []}}} = base} <- decode.(encoded),
         record = put_in(base.spec.command.args, args),
         :ok <- Execution.validate(record),
         do: {:ok, record},
         else: (_ -> invalid())
  rescue
    ArgumentError -> invalid()
  end

  def decode(_, _), do: invalid()
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
