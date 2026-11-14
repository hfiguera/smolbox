defmodule SmolBox.DurableHost.KubernetesBinding do
  @moduledoc false
  alias SmolBox.Kubernetes.Binding

  if Code.ensure_loaded?(Binding) do
    # Separate authenticated enrollment authority. SQL kind/generation remain
    # projections and cannot authorize another namespace/node after tampering.
    def encrypt(context, binding) do
      nonce = :crypto.strong_rand_bytes(12)
      bytes = :erlang.term_to_binary(binding)
      aad = aad(context, binding.target_id)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, context.key, nonce, bytes, aad, 16, true)

      <<1, nonce::binary, tag::binary, ciphertext::binary>>
    end

    def decrypt(
          context,
          worker,
          generation,
          <<1, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>
        )
        when byte_size(ciphertext) <= 32_768 do
      Code.ensure_loaded!(Binding)

      with <<131, etf_tag, _::binary>> = bytes when etf_tag != 80 <-
             :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               context.key,
               nonce,
               ciphertext,
               aad(context, worker),
               tag,
               false
             ),
           {binding, used} <- :erlang.binary_to_term(bytes, [:safe, :used]),
           true <- used == byte_size(bytes),
           true <-
             Binding.valid?(binding) and binding.target_id == worker and
               binding.generation == generation,
           do: {:ok, binding},
           else: (_ -> error())
    rescue
      ArgumentError -> error()
    end

    def decrypt(_, _, _, _), do: error()

    defp aad(context, worker),
      do: :erlang.term_to_binary({"smolbox-kubernetes-binding-v1", context.partition, worker})

    defp error, do: {:error, %SmolBox.Error{category: :store, operation: :bind_backend}}
  end
end
