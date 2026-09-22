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
  Image writes use v2, including offline executions. Checkpoint records use v3;
  v1/v2 envelopes cannot contain checkpoint references. Upgrade all controllers
  sharing a store before accepting checkpoints; older readers cannot read v3.
  See [Checkpoint upgrades](checkpoints.html#persistence-and-upgrades). Follow
  [Upgrading to 0.1.3](recovery.html#upgrading-to-0-1-3) across all controllers.
  Managed machines and associated commands use v4. Disposable writes retain their
  v2/v3 shape, omitting the empty managed-machine reference; old payloads gain that
  field on read. Upgrade every controller sharing workers before enabling retained
  reservations. See [Persistent-machine upgrades](persistent-machines.html#store-contract-and-upgrades).
  Silently treating undecodable records as absent
  would permit replay and is forbidden.
  """

  alias SmolBox.{Error, Execution}

  @max_bytes 16_777_216
  @prefix "smolbox-record-v2\0"
  @checkpoint_prefix "smolbox-record-v3\0"
  @managed_prefix "smolbox-record-v4\0"
  @legacy_prefix "smolbox-record-v1\0"
  @record_modules [
    Execution,
    SmolBox.ManagedMachine,
    SmolBox.ManagedMachineSpec,
    SmolBox.ExecutionSpec,
    SmolBox.ExecutionValidation,
    SmolBox.Command,
    SmolBox.Profile,
    SmolBox.NetworkPolicy,
    SmolBox.Machine,
    SmolBox.Result,
    Error
  ]

  @spec encode(Execution.t() | SmolBox.ManagedMachine.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def encode(%SmolBox.ManagedMachine{} = record), do: encode_managed(record)

  def encode(%Execution{managed_machine: key} = record) when not is_nil(key),
    do: encode_managed(record)

  def encode(record) do
    with :ok <- Execution.validate(record) do
      prefix = if checkpoint_record?(record), do: @checkpoint_prefix, else: @prefix
      bytes = prefix <> :erlang.term_to_binary(Map.delete(record, :managed_machine))
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  @spec decode(binary()) ::
          {:ok, Execution.t() | SmolBox.ManagedMachine.t()} | {:error, Error.t()}
  def decode(<<@prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    decode_version(bytes, false, false)
  end

  def decode(<<@legacy_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_version(bytes, true, false)

  def decode(<<@checkpoint_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes,
      do: decode_version(bytes, false, true)

  def decode(<<@managed_prefix, 131, tag, _rest::binary>> = bytes)
      when tag != 80 and byte_size(bytes) <= @max_bytes do
    Enum.each(@record_modules, &Code.ensure_loaded!/1)

    payload =
      binary_part(
        bytes,
        byte_size(@managed_prefix),
        byte_size(bytes) - byte_size(@managed_prefix)
      )

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload),
         :ok <- validate_managed(record) do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  def decode(_bytes), do: invalid()

  defp encode_managed(record) do
    with :ok <- validate_managed(record) do
      bytes = @managed_prefix <> :erlang.term_to_binary(record)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: invalid()
    end
  end

  defp validate_managed(%SmolBox.ManagedMachine{} = record),
    do: SmolBox.ManagedMachine.validate(record)

  defp validate_managed(%Execution{managed_machine: key} = record) when not is_nil(key),
    do: Execution.validate(record)

  defp validate_managed(_record), do: invalid()

  defp decode_version(bytes, legacy?, checkpoint?) do
    with {:ok, record} <- decode_payload(bytes, legacy?),
         true <- checkpoint_record?(record) == checkpoint? do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  end

  defp checkpoint_record?(%{spec: %{artifact: %{"kind" => "checkpoint"}}}), do: true
  defp checkpoint_record?(_record), do: false

  defp decode_payload(bytes, legacy?) do
    # A fresh BEAM must load the finite schema vocabulary before safe decoding;
    # persisted bytes never get to intern new atoms themselves.
    Enum.each(@record_modules, &Code.ensure_loaded!/1)
    payload = binary_part(bytes, byte_size(@prefix), byte_size(bytes) - byte_size(@prefix))

    with {record, used} <- :erlang.binary_to_term(payload, [:safe, :used]),
         true <- used == byte_size(payload),
         {:ok, record} <- upgrade(record, legacy?),
         :ok <- Execution.validate(record),
         true <- record.managed_machine == nil do
      {:ok, record}
    else
      _invalid -> invalid()
    end
  rescue
    ArgumentError -> invalid()
  end

  defp upgrade(%Execution{} = record, false),
    do: {:ok, Map.put_new(record, :managed_machine, nil)}

  defp upgrade(_record, false), do: invalid()

  defp upgrade(%Execution{spec: %SmolBox.ExecutionSpec{profile: profile}} = record, true) do
    with {:ok, profile} <- legacy_field(profile, SmolBox.Profile),
         {:ok, machine} <- legacy_field(record.created_machine, SmolBox.Machine) do
      {:ok,
       Map.put_new(
         %{record | spec: %{record.spec | profile: profile}, created_machine: machine},
         :managed_machine,
         nil
       )}
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
