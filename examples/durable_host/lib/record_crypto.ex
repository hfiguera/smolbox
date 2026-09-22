defmodule SmolBox.DurableHost.RecordCrypto do
  @moduledoc false
  alias SmolBox.{Error, Execution}
  alias SmolBox.Store.Codec

  @spec encrypt(Execution.t() | SmolBox.ManagedMachine.t(), binary(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def encrypt(record, key, partition) when byte_size(key) == 32 do
    with {:ok, bytes} <- Codec.encode(record) do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          bytes,
          aad(partition, {record.scope, record.id}, kind(record)),
          16,
          true
        )

      {:ok, <<1, nonce::binary, tag::binary, ciphertext::binary>>}
    end
  end

  @spec decrypt(binary(), binary(), String.t(), Execution.key()) ::
          {:ok, Execution.t() | SmolBox.ManagedMachine.t()} | {:error, Error.t()}
  def decrypt(bytes, key, partition, identity, kind \\ :execution)

  def decrypt(
        <<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>,
        key,
        partition,
        identity,
        kind
      )
      when byte_size(key) == 32 and byte_size(ciphertext) <= 16_777_216 do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           nonce,
           ciphertext,
           aad(partition, identity, kind),
           tag,
           false
         ) do
      :error ->
        invalid()

      bytes ->
        with {:ok, record} <- Codec.decode(bytes),
             true <- {record.scope, record.id} == identity and kind(record) == kind do
          {:ok, record}
        else
          _invalid -> invalid()
        end
    end
  end

  def decrypt(_bytes, _key, _partition, _identity, _kind), do: invalid()

  defp kind(%SmolBox.ManagedMachine{}), do: :machine
  defp kind(%Execution{}), do: :execution

  defp aad(partition, {scope, id}, :machine),
    do: :erlang.term_to_binary({"smolbox-host-machine-v1", partition, scope, id})

  defp aad(partition, {scope, id}, :execution),
    do: :erlang.term_to_binary({"smolbox-host-record-v1", partition, scope, id})

  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
