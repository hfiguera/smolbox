defmodule SmolBox.ManagedMachineTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Execution, ManagedMachine, ManagedMachineSpec}
  alias SmolBox.Store.{Codec, Contract, MachineContract, Memory}

  test "machine and command envelopes round trip while disposable bytes keep their prior shape" do
    machine = MachineContract.record()
    assert {:ok, <<"smolbox-record-v5\0", _::binary>> = bytes} = Codec.encode(machine)
    assert {:ok, ^machine} = Codec.decode(bytes)
    execution = Contract.record()
    assert {:ok, <<"smolbox-record-v2\0", payload::binary>> = bytes} = Codec.encode(execution)
    refute Map.has_key?(:erlang.binary_to_term(payload), :managed_machine)
    assert {:ok, ^execution} = Codec.decode(bytes)
    store = start_supervised!(Memory)
    running = MachineContract.running(Memory, store)

    {:ok, command} =
      Memory.machine(store, :submit, [ManagedMachine.key(running), execution, 10, 1100])

    assert {:ok, <<"smolbox-record-v5\0", _::binary>> = bytes} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(bytes)
    assert Execution.validate(command) == :ok
  end

  test "malformed machine state, live values, compressed payloads and trailing bytes are rejected" do
    machine = MachineContract.record()

    for patch <- [
          %{scope: "elsewhere"},
          %{version: 0},
          %{spec: %{machine.spec | profile: nil}},
          %{active_execution: self()},
          %{last_error: make_ref()},
          %{state: :running},
          %{observed_machine: fn -> :unsafe end}
        ] do
      invalid = struct!(machine, patch)
      assert {:error, _} = ManagedMachine.validate(invalid)
      assert {:error, _} = Codec.decode("smolbox-record-v5\0" <> :erlang.term_to_binary(invalid))
    end

    assert {:error, _} = ManagedMachineSpec.validate(Map.put(machine.spec, :unexpected, true))
    {:ok, bytes} = Codec.encode(machine)
    assert {:error, _} = Codec.decode(bytes <> "extra")

    assert {:error, _} =
             Codec.decode("smolbox-record-v5\0" <> :erlang.term_to_binary(machine, compressed: 9))

    assert {:error, _} = Codec.decode("smolbox-record-v6\0" <> :erlang.term_to_binary(machine))
  end

  test "machine and command records share memory bounds and failed transactions leave no busy slot" do
    tiny = start_supervised!({Memory, max_bytes: 1}, id: :tiny)
    assert {:error, _} = Memory.machine(tiny, :accept, [MachineContract.record(), 10])

    assert {:error, %{category: :not_found}} =
             Memory.machine(tiny, :fetch, [{"contract", "computer"}])

    bounded = start_supervised!({Memory, max_records: 1}, id: :bounded)
    running = MachineContract.running(Memory, bounded)

    assert {:error, %{category: :admission_exhausted}} =
             Memory.machine(bounded, :submit, [
               ManagedMachine.key(running),
               Contract.record(),
               10,
               1100
             ])

    assert {:ok, %{active_execution: nil}} =
             Memory.machine(bounded, :fetch, [ManagedMachine.key(running)])
  end
end
