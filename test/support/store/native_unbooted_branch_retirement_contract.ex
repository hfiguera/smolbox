defmodule SmolBox.Store.NativeUnbootedBranchRetirementContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{NativeBranchRetirement, UnbootedBranchChildAbsence}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Contract,
    MachineOps,
    NativeBranchRetirementContract,
    NativeUnbootedBranchDisposalContract
  }

  def prepare(adapter, store, hold, provenance \\ "deleted") do
    {parent, child, _, usage} =
      NativeUnbootedBranchDisposalContract.complete(adapter, store, hold, provenance)

    assert {:error, _} = MachineOps.request(parent, :stop, parent.version, 1200)
    {parent, child, proof(child), usage}
  end

  def proof(child) do
    assert {:ok, request} = NativeBranchRetirement.request(child)
    proof_from_request(request)
  end

  def proof_from_request(request) do
    wire = %{"schema" => 1, "request" => request}
    wire = Map.put(wire, "proof_sha256", UnbootedBranchChildAbsence.proof_digest(wire))
    assert {:ok, proof} = UnbootedBranchChildAbsence.from_wire(wire)
    proof
  end

  defdelegate advance(adapter, store, parent, child, proof, now),
    to: NativeBranchRetirementContract

  defdelegate fetch(adapter, store, record), to: NativeUnbootedBranchDisposalContract

  def complete(adapter, store, hold, provenance \\ "deleted") do
    {parent, child, proof, usage} = prepare(adapter, store, hold, provenance)
    assert {:ok, <<"smolbox-record-v37", 0, _::binary>>} = before = Codec.encode(child)

    for invalid <- [
          :absent,
          proof.request,
          UnbootedBranchChildAbsence.to_wire(proof),
          proof_from_request(
            NativeBranchRetirement.unbooted_intent(
              child.branch.native_authority,
              child.version + 1
            )
          )
        ] do
      assert {:error, _} = advance(adapter, store, parent, child, invalid, 1201)
      assert fetch(adapter, store, parent) == parent
      assert fetch(adapter, store, child) == child
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:ok, retired} = advance(adapter, store, parent, child, proof, 1201)
    source = fetch(adapter, store, parent)
    assert retired.branch.state == :retired and retired.state == :deleted
    assert retired.branch.retired_at_ms == 1201
    assert retired.created_machine == nil and retired.observed_machine == nil
    assert retired.branch.native_authority.completion == nil
    assert retired.branch.native_authority.disposal == child.branch.native_authority.disposal
    assert retired.branch.native_authority.retirement.version == child.version
    assert retired.branch.native_authority.retirement.proof == proof
    assert source.branch_children == %{child.id => true}
    assert source.native_branch_history == parent.native_branch_history

    assert source.created_machine == parent.created_machine and
             source.observed_machine == parent.observed_machine

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^retired} = advance(adapter, store, source, retired, proof, 1202)
    assert {:error, _} = advance(adapter, store, parent, child, proof, 1202)
    assert {:ok, _} = MachineOps.request(source, :stop, source.version, 1202)

    assert {:error, _} =
             adapter.machine(store, :branch_release_storage, [
               ManagedMachine.key(source),
               Contract.guard(source),
               child.id,
               1202
             ])

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, child} = Codec.decode(elem(before, 1))
    assert Codec.encode(child) == before
    roundtrip(retired)
    assert {:ok, source_bytes} = Codec.encode(source)
    assert {:ok, ^source} = Codec.decode(source_bytes)
    {source, retired, proof, usage}
  end

  def roundtrip(record) do
    assert {:ok, <<"smolbox-record-v38", 0, body::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 1..37 do
      assert {:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> body)
    end

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v38" <> <<0>> <> :erlang.term_to_binary(record, compressed: 9)
             )

    bytes
  end
end
