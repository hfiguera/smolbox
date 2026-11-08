defmodule SmolBox.Store.NativeBranchRetirementContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{BranchCanonical, BranchChildAbsence, NativeBranchRetirement}
  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    Contract,
    MachineOps,
    NativeBranchContract,
    NativeBranchReleaseContract
  }

  def prepare(adapter, store, mode) do
    {parent, child, _, _} =
      case mode do
        :held -> NativeBranchContract.complete(adapter, store, true)
        :ready -> NativeBranchContract.complete(adapter, store, false)
        :released -> NativeBranchReleaseContract.completed(adapter, store)
      end

    assert {:ok, usage} = adapter.usage(store, parent.worker_id)

    assert {:error, _} =
             adapter.machine(store, :request, [
               ManagedMachine.key(parent),
               :stop,
               parent.version,
               1300
             ])

    assert {:ok, child} =
             adapter.machine(store, :claim, [ManagedMachine.key(child), "owner", 1300, 10_000])

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(child),
               :delete,
               child.version,
               1301
             ])

    assert {:ok, gone} =
             adapter.machine(store, :write, [
               ManagedMachine.key(child),
               Contract.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: 1302
               ],
               1302
             ])

    assert {:ok, after_deletion} = adapter.usage(store, parent.worker_id)

    assert after_deletion ==
             Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)

    assert {:ok, parent} =
             adapter.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1303, 10_000])

    assert {:error, _} =
             adapter.machine(store, :branch_retire, [
               ManagedMachine.key(parent),
               Contract.guard(parent),
               child.id,
               1303
             ])

    {parent, gone, proof(gone), after_deletion}
  end

  # Synthetic proof only. This helper supplies no VM, SDK or native enrollment.
  def proof(child) do
    assert {:ok, request} = NativeBranchRetirement.request(child)
    proof_from_request(request)
  end

  def proof_from_request(request) do
    proof = %BranchChildAbsence{
      schema: 1,
      request: request,
      proof_sha256:
        BranchCanonical.digest([
          "smolbox-branch-child-absence-v1",
          1,
          BranchCanonical.ordered(request, :child_absence_request)
        ])
    }

    assert BranchChildAbsence.valid?(proof)
    proof
  end

  def advance(adapter, store, parent, child, proof, now),
    do:
      adapter.machine(store, :branch_retire, [
        ManagedMachine.key(parent),
        Contract.guard(parent),
        child.id,
        proof,
        now
      ])

  def complete(adapter, store, mode) do
    {parent, child, proof, usage} = prepare(adapter, store, mode)

    for invalid <- [
          :absent,
          proof.request,
          BranchChildAbsence.to_wire(proof),
          proof_from_request(
            NativeBranchRetirement.intent(
              child.branch.native_authority,
              child.version + 1,
              proof.request["child"]
            )
          )
        ] do
      assert {:error, _} = advance(adapter, store, parent, child, invalid, 1304)
      assert {:ok, ^parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert {:ok, ^child} = adapter.machine(store, :fetch, [ManagedMachine.key(child)])
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:ok, retired} = advance(adapter, store, parent, child, proof, 1304)
    assert {:ok, source} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert retired.branch.state == :retired and retired.state == :deleted
    assert retired.branch.retired_at_ms == 1304
    assert retired.branch.native_authority.retirement.version == child.version
    assert retired.branch.native_authority.retirement.proof == proof

    assert retired.created_machine == child.created_machine and
             retired.observed_machine == child.observed_machine

    assert source.branch_children == %{child.id => true}
    assert source.native_branch_history == parent.native_branch_history

    assert source.created_machine == parent.created_machine and
             source.observed_machine == parent.observed_machine

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:error, _} = advance(adapter, store, parent, child, proof, 1305)
    assert {:ok, ^retired} = advance(adapter, store, source, retired, proof, 1305)
    assert {:ok, _} = MachineOps.request(source, :stop, source.version, 1305)

    assert {:error, _} =
             adapter.machine(store, :branch_release_storage, [
               ManagedMachine.key(source),
               Contract.guard(source),
               child.id,
               1305
             ])

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    roundtrip(retired)
    assert {:ok, <<"smolbox-record-v30\0", _::binary>> = source_bytes} = Codec.encode(source)
    assert {:ok, ^source} = Codec.decode(source_bytes)
    {source, retired, proof, usage}
  end

  def roundtrip(retired) do
    assert {:ok, <<"smolbox-record-v32\0", body::binary>> = bytes} = Codec.encode(retired)
    assert {:ok, ^retired} = Codec.decode(bytes)

    for version <- 1..31,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v32\0" <> :erlang.term_to_binary(retired, compressed: 9)
             )

    bytes
  end
end
