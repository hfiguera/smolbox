defmodule SmolBox.ExportStoreTest do
  use SmolBox.Store.ExportContract, async: true
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, Contract, ExportContract, Memory}

  setup do: %{adapter: Memory, store: start_supervised!(Memory)}

  test "export history selects v11 and older envelopes cannot smuggle export operations", %{
    store: store
  } do
    machine = ExportContract.stopped(Memory, store)
    assert {:ok, encoded} = Codec.encode(machine)
    assert {:ok, ^machine} = Codec.decode(encoded)
    refute encoded =~ "smolbox-record-v11"
    assert {:ok, active} = ExportContract.accept(Memory, store, machine)
    assert {:ok, <<"smolbox-record-v11\0", payload::binary>> = bytes} = Codec.encode(active)
    assert {:ok, ^active} = Codec.decode(bytes)

    for version <- 1..10,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> payload))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    assert {:error, _} = Codec.encode(%{active | exports: %{}})
    assert {:error, _} = Codec.encode(%{active | active_export: nil})
    assert {:error, _} = Codec.encode(%{active | active_execution: {active.scope, "command"}})

    assert {:error, _} =
             Memory.machine(store, :write, [
               ManagedMachine.key(active),
               Contract.guard(active),
               [state: :deleted],
               1200
             ])
  end
end
