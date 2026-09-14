defmodule SmolBox.Store.Codec do
  @moduledoc """
  Versioned data-only record encoding for trusted host store adapters.

  This is an internal persistence format, never an endpoint for guest or public
  input. Records are validated before encoding and after safe decoding. Compressed
  terms, trailing bytes, unknown schemas, unexpected structs/keys, PIDs, refs,
  ports, and closures are rejected. Payloads have a fixed 16 MiB cap.

  Encoding does not encrypt secrets. Durable adapters must authenticate and encrypt
  these bytes or use an explicitly approved equivalent secure storage policy.
  Schema v2 adds network policy. Exact v1 records are upgraded to offline defaults
  on read; offline fingerprints are unchanged. Old readers cannot read v2 writes.
  Every write uses v2, including offline executions. Follow
  [Upgrading to 0.1.3](recovery.html#upgrading-to-0-1-3) across all controllers.
  Silently treating undecodable records as absent
  would permit replay and is forbidden.
  """

  alias SmolBox.{Error, Execution}

  @max_bytes 16_777_216
  @prefix "smolbox-record-v2\0"
  @legacy_prefix "smolbox-record-v1\0"
  @record_modules [
    Execution,
    SmolBox.ExecutionSpec,
    SmolBox.ExecutionValidation,
    SmolBox.Command,
    SmolBox.Profile,
    SmolBox.NetworkPolicy,
    SmolBox.Machine,
    SmolBox.Result,
    Error
  ]

  @spec encode(Execution.t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(record) do
    with :ok <- Execution.validate(record) do
      bytes = @prefix <> :erlang.term_to_binary(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  @spec decode(binary()) :: {:ok, Execution.t()} | {:error, Error.t()}
  def decode(<<@prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    decode_payload(bytes, false)
  end

  def decode(<<@legacy_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_payload(bytes, true)

  def decode(_bytes), do: invalid()

  defp decode_payload(bytes, legacy?) do
    # A fresh BEAM must load the finite schema vocabulary before safe decoding;
    # persisted bytes never get to intern new atoms themselves.
    Enum.each(@record_modules, &Code.ensure_loaded!/1)
    payload = binary_part(bytes, byte_size(@prefix), byte_size(bytes) - byte_size(@prefix))

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload),
         {:ok, record} <- upgrade(record, legacy?),
         :ok <- Execution.validate(record) do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp upgrade(record, false), do: {:ok, record}

  defp upgrade(%Execution{spec: %SmolBox.ExecutionSpec{profile: profile}} = record, true) do
    with {:ok, profile} <- legacy_field(profile, SmolBox.Profile),
         {:ok, machine} <- legacy_field(record.created_machine, SmolBox.Machine) do
      {:ok, %{record | spec: %{record.spec | profile: profile}, created_machine: machine}}
    end
  end

  defp upgrade(_record, true), do: invalid()
  defp legacy_field(nil, SmolBox.Machine), do: {:ok, nil}

  defp legacy_field(value, module) when is_map(value) do
    expected = module |> struct() |> Map.keys() |> List.delete(:network) |> Enum.sort()

    if Map.get(value, :__struct__) == module and Enum.sort(Map.keys(value)) == expected,
      do: {:ok, Map.put(value, :network, :offline)},
      else: invalid()
  end

  defp legacy_field(_value, _module), do: invalid()
  defp invalid, do: {:error, %Error{category: :store, operation: :codec}}
end
