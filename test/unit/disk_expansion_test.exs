defmodule SmolBox.DiskExpansionUnitTest do
  use ExUnit.Case, async: true
  alias SmolBox.{DiskExpansion, ManagedMachine}
  alias SmolBox.Store.{Codec, Contract, ExpansionContract, ExpansionOps, Memory}

  test "invalid targets and checkpoint relationships cannot become growth intent" do
    store = start_supervised!(Memory)
    m = ExpansionContract.stopped(Memory, store)

    for options <- [
          [],
          [storage_gb: 0],
          [overlay_gb: 65],
          [storage_gb: 2.5],
          [other: 2],
          [storage_gb: 2, storage_gb: 3]
        ] do
      assert {:error, %{category: :validation}} = DiskExpansion.targets(options)
    end

    for spec <- [
          %{m.spec | checkpointable: true},
          %{m.spec | artifact: Map.put(m.spec.artifact, "kind", "checkpoint")}
        ] do
      assert {:error, %{category: :unsupported_capability}} =
               ExpansionOps.accept(
                 %{m | spec: spec},
                 "no",
                 m.version,
                 %{storage_gb: 3},
                 Contract.capacity(20),
                 m.reservation,
                 1100
               )
    end
  end

  test "successive increases retain verified sizes and reject forged or downgraded history" do
    store = start_supervised!(Memory)
    original = ExpansionContract.stopped(Memory, store)
    {:ok, pending} = ExpansionContract.accept(Memory, store, original)
    {:ok, sent} = ExpansionContract.advance(Memory, store, pending, :dispatch)
    first = %{original.created_machine | state: :stopped, storage_gb: 3, overlay_gb: 2}
    {:ok, grown} = ExpansionContract.advance(Memory, store, sent, {:complete, first})
    {:ok, second} = ExpansionContract.accept(Memory, store, grown, "second", %{overlay_gb: 4})
    {:ok, sent} = ExpansionContract.advance(Memory, store, second, :dispatch)

    {:ok, unknown} =
      ExpansionContract.advance(
        Memory,
        store,
        sent,
        {:unknown, %SmolBox.Error{category: :transport, operation: :expand_disks}}
      )

    {:ok, resolved} =
      ExpansionContract.advance(Memory, store, unknown, {:resolve, %{first | overlay_gb: 4}})

    assert resolved.disk_sizes == %{storage_gb: 3, overlay_gb: 4}
    assert resolved.reservation.disk_gb == 7
    assert resolved.disk_expansions["second"].state == :resolved

    assert {:error, %{category: :validation}} =
             ExpansionContract.accept(Memory, store, resolved, "shrink", %{storage_gb: 2})

    assert {:error, _} =
             ExpansionContract.advance(Memory, store, sent, {:complete, %{first | overlay_gb: 4}})

    for invalid <- [
          %{resolved | disk_sizes: %{storage_gb: 1, overlay_gb: 1}},
          %{resolved | reservation: original.reservation},
          %{resolved | disk_expansions: %{bad: :bad}},
          %{resolved | active_expansion: "second"}
        ] do
      assert {:error, _} = ManagedMachine.validate(invalid)
      assert {:error, _} = Codec.decode("smolbox-record-v14\0" <> :erlang.term_to_binary(invalid))
    end

    assert {:ok, old = <<"smolbox-record-v5\0", _::binary>>} = Codec.encode(original)
    assert {:ok, ^original} = Codec.decode(old)

    assert {:error, _} =
             Codec.decode(String.replace_prefix(old, "smolbox-record-v5", "smolbox-record-v14"))

    assert {:ok, bytes} = Codec.encode(resolved)
    assert {:error, _} = Codec.decode(bytes <> <<0>>)

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v14\0" <> :erlang.term_to_binary(resolved, compressed: 9)
             )
  end
end
