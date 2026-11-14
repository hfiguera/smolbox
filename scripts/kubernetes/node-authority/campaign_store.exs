defmodule SmolBox.NodeAuthorityCampaign.Store do
  @moduledoc false
  @behaviour SmolBox.Store
  alias SmolBox.{Execution, Files}
  alias SmolBox.Kubernetes.CleanupProof
  alias SmolBox.Store.Codec

  # Manual observation wrapper only. Every operation still uses the real
  # adapter, including claims, authenticated reads, writes and guarded release.
  for {operation, arity} <- SmolBox.Store.behaviour_info(:callbacks), operation != :release do
    [context | arguments] = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    def unquote(operation)(unquote(context), unquote_splicing(arguments)),
      do: invoke(unquote(context), unquote(operation), [unquote_splicing(arguments)])
  end

  @impl true
  def release(context, key, guard, now) do
    {:ok, before} = forward(context, :fetch, [key])

    if before.reservation != nil do
      true = before.cleanup == :complete
      true = CleanupProof.releasable?(before.backend_cleanup, before.backend_receipt)
      {:ok, encoded} = Codec.encode(before)

      event(context, %{
        event: "proof_persisted_before_release",
        key: Tuple.to_list(key),
        record_sha256: Files.sha256(encoded),
        reservation_held: true,
        proof: data(before.backend_cleanup)
      })
    end

    result = forward(context, :release, [key, guard, now])
    observe(context, :release, result)
    result
  end

  defp invoke(context, operation, args) do
    result = forward(context, operation, args)
    lease(context, operation, result)
    observe(context, operation, result)
    result
  end

  defp lease(context, :claim_worker, {:ok, lease}),
    do:
      event(context, %{
        event: "worker_lease",
        lease: Map.take(lease, [:owner, :generation, :until_ms])
      })

  defp lease(_, _, _), do: :ok

  defp observe(context, operation, {:ok, %Execution{} = record}),
    do: snapshot(context, operation, record)

  defp observe(context, operation, {:ok, %Execution{} = record, _}),
    do: snapshot(context, operation, record)

  defp observe(_, _, _), do: :ok

  defp snapshot(context, operation, record) do
    {:ok, encoded} = Codec.encode(record)
    key = Tuple.to_list(Execution.key(record))
    id = key |> Jason.encode!() |> Files.sha256()
    destination = Path.join(context.directory, id <> ".record")
    temporary = destination <> "." <> Base.encode16(:crypto.strong_rand_bytes(9)) <> ".part"
    File.write!(temporary, encoded, [:exclusive, :sync])
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, destination)

    event(context, %{
      event: "adapter_result",
      operation: operation,
      key: key,
      state: record.state,
      cleanup: record.cleanup,
      collection: record.collection,
      reservation_held: record.reservation != nil,
      pod_uid: record.backend_receipt && record.backend_receipt.pod_uid,
      result_exit: record.result && record.result.exit_code,
      record_sha256: Files.sha256(encoded)
    })
  end

  defp event(context, value) do
    path = Path.join(context.directory, "store-observations.jsonl")

    File.write!(
      path,
      Jason.encode!(Map.put(value, :at_unix_ms, System.system_time(:millisecond))) <> "\n",
      [:append, :sync]
    )

    File.chmod!(path, 0o600)
  end

  defp data(value) when is_struct(value), do: value |> Map.from_struct() |> data()

  defp data(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), data(item)} end)

  defp data(value) when is_list(value), do: Enum.map(value, &data/1)
  defp data(value), do: value

  defp forward(%{delegate: {adapter, store}}, operation, args),
    do: apply(adapter, operation, [store | args])
end
