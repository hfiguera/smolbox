defmodule SmolBox.SourceStoreTest do
  use SmolBox.Store.SourceContract, async: true
  alias SmolBox.Store.{Codec, ImageContract, Memory, SourceContract}

  setup do
    %{adapter: Memory, store: start_supervised!(Memory)}
  end

  test "managed image pull storage contract", %{adapter: adapter, store: store} do
    ImageContract.pull(adapter, store)
  end

  test "remote identities use v10 and cannot be smuggled into older envelopes" do
    record = SourceContract.record()
    assert {:ok, <<"smolbox-record-v10\0", payload::binary>> = encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)

    for version <- 1..9 do
      assert {:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload)
    end

    assert {:error, _} = Codec.decode(encoded <> "trailing")

    assert {:error, _} =
             Codec.decode("smolbox-record-v10\0" <> :erlang.term_to_binary(record, compressed: 9))

    invalid = put_in(record.spec.artifact["identity_token"], "sensitive")
    assert {:error, _} = Codec.encode(invalid)
    assert {:error, _} = Codec.decode("smolbox-record-v10\0" <> :erlang.term_to_binary(invalid))
  end

  test "credential reference participates in identity without token material" do
    record = SourceContract.record()
    spec = put_in(record.spec.artifact["credential_ref"], "other-reader").spec
    key = :binary.copy(<<1>>, 32)
    refute SmolBox.ManagedMachineSpec.fingerprint(spec, key) == {:ok, record.fingerprint}
    assert {:ok, bytes} = Codec.encode(record)
    assert bytes =~ "registry-reader"
    refute bytes =~ "identityToken"
  end
end
