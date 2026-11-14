defmodule SmolBox.KubernetesCodecTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Execution, ExecutionSpec}
  alias SmolBox.Kubernetes.Receipt
  alias SmolBox.Store.{BackendContract, Codec, Contract, RecordOps}
  alias SmolBox.Test.Kubernetes, as: Fixture

  test "pre-Kubernetes HTTP and Embedded bytes and fingerprints remain exact" do
    fixtures =
      File.read!("test/fixtures/kubernetes/pre-kubernetes-codecs.json") |> Jason.decode!()

    assert fixtures["source_commit"] == "8eb2dcb6"

    for fixture <- fixtures["records"] do
      stored_bytes = Base.decode64!(fixture["encoded"])
      # The production decoder loads record modules before safe ETF inspection.
      # Do not depend on other test modules having already interned these atoms.
      assert {:ok, _record} = Codec.decode(stored_bytes)
      [prefix, payload] = :binary.split(stored_bytes, <<0>>)
      # ETF map order depends on this VM's atom table. Apply the original ETF
      # writer to the untouched golden payload in this VM before comparing bytes.
      bytes = prefix <> <<0>> <> :erlang.term_to_binary(:erlang.binary_to_term(payload, [:safe]))
      assert {:ok, record} = Codec.decode(bytes)
      assert record.fingerprint == fixture["fingerprint"]
      assert {:ok, ^bytes} = Codec.encode(record)
      assert record.backend_receipt == nil
      assert record.backend_cleanup == nil
      assert record.backend_create_state == nil
      assert {:ok, fingerprint} = ExecutionSpec.fingerprint(record.spec, :binary.copy(<<1>>, 32))
      assert fingerprint == record.fingerprint
    end
  end

  test "selective v54 preserves queued, reserved and original UID receipt authority" do
    {:ok, config} = Fixture.config()
    {reserved, assignment} = Fixture.assigned(config)
    {:ok, created} = Receipt.created(assignment, "pod-original")

    assert {:ok, dispatched} =
             Execution.transition(reserved, [backend_create_state: :dispatched], 1000)

    assert {:ok, saved} = Execution.transition(dispatched, [backend_receipt: created], 1000)

    assert {:ok, ready} =
             Execution.transition(
               saved,
               [backend_receipt: Fixture.ready_receipt(assignment)],
               1000
             )

    for record <- [Fixture.execution(config), reserved, dispatched, saved, ready] do
      assert {:ok, <<"smolbox-record-v54\0", _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
      assert {:error, _} = Codec.decode(bytes <> "extra")

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v54\0" <> :erlang.term_to_binary(%{record | schema: 2})
               )

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v54\0" <> :erlang.term_to_binary(Map.put(record, :extra, true))
               )

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v54\0" <> :erlang.term_to_binary(record, compressed: 9)
               )
    end
  end

  test "every older envelope rejects Kubernetes including queued identity and smuggled defaults" do
    {:ok, config} = Fixture.config()
    {reserved, _} = Fixture.assigned(config)
    queued = Fixture.execution(config)
    http = Contract.record()

    for version <- 1..53, record <- [queued, reserved, http] do
      # The HTTP case deliberately includes the newly introduced nil fields.
      assert {:error, _} =
               Codec.decode("smolbox-record-v#{version}\0" <> :erlang.term_to_binary(record))
    end

    assert {:error, _} = Codec.decode("smolbox-record-v55\0" <> :erlang.term_to_binary(queued))
    assert {:error, _} = Codec.decode("smolbox-record-v54\0" <> :erlang.term_to_binary(http))
  end

  test "old envelope cannot hide new authority behind nil assignment or positive retention" do
    record = Contract.record()
    {:ok, claimed} = RecordOps.claim(record, nil, "owner", 1100, 10_000)
    assignment = BackendContract.assignment(claimed, "native-compat")

    for forged <- [
          %{record | backend_cleanup: :not_dispatched},
          %{record | backend_receipt: self()},
          %{record | backend_create_state: :pending},
          %{record | backend_assignment: assignment, backend_create_state: :dispatched}
        ] do
      assert {:error, _} = Codec.encode(forged)
    end
  end
end
