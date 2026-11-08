defmodule SmolBox.Store.NativeBranchDeletionContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{BranchCanonical, BranchDeletionResolution}
  alias SmolBox.{ManagedMachine, Profile}
  alias SmolBox.Store.{Codec, Contract, NativeBranchContract, NativeBranchReleaseContract}

  def prepare(adapter, store, mode \\ :held) do
    {parent, child, _, _} =
      case mode do
        :held -> NativeBranchContract.complete(adapter, store, true)
        :ready -> NativeBranchContract.complete(adapter, store, false)
        :released -> NativeBranchReleaseContract.completed(adapter, store)
      end

    assert {:ok, child} =
             adapter.machine(store, :claim, [ManagedMachine.key(child), "owner", 1300, 10_000])

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(child),
               :delete,
               child.version,
               1301
             ])

    assert {:ok, child} =
             adapter.machine(store, :write, [
               ManagedMachine.key(deleting),
               Contract.guard(deleting),
               [state: :unknown, phase: :uncertain],
               1302
             ])

    assert {:ok, usage} = adapter.usage(store, parent.worker_id)
    {parent, child, usage}
  end

  def denied_released(adapter, store, mode) when mode in [:ready, :released] do
    {parent, child, usage} = prepare(adapter, store, mode)
    assert {:ok, before} = Codec.encode(child)

    assert {:error, _} =
             adapter.machine(store, :resolve, [
               ManagedMachine.key(child),
               Contract.guard(child),
               :absent,
               1303
             ])

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{state: :deleted, operation: nil, phase: nil, reservation: nil},
               1303
             )

    assert {:ok, ^child} = adapter.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^before} = Codec.encode(child)
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    {parent, child, usage}
  end

  def accept(adapter, store, child, now),
    do:
      adapter.machine(store, :branch_delete_accept, [
        ManagedMachine.key(child),
        Contract.guard(child),
        now
      ])

  def resolve(adapter, store, child, proof, now),
    do:
      adapter.machine(store, :resolve, [
        ManagedMachine.key(child),
        Contract.guard(child),
        proof,
        now
      ])

  def fetch(adapter, store, child) do
    assert {:ok, child} = adapter.machine(store, :fetch, [ManagedMachine.key(child)])
    child
  end

  def proof(request) do
    deletion = String.duplicate("a", 64)

    proof = %BranchDeletionResolution{
      schema: 1,
      child: request["child"],
      operation_id: request["operation_id"],
      request_sha256: request["request_sha256"],
      deletion_sha256: deletion,
      proof_sha256:
        BranchCanonical.digest([
          "smolbox-held-child-delete-resolution-v1",
          1,
          BranchCanonical.ordered(request["child"], :receipt),
          request["operation_id"],
          request["request_sha256"],
          deletion
        ])
    }

    assert BranchDeletionResolution.matches?(proof, request)
    proof
  end

  def complete(adapter, store) do
    {parent, child, usage} = prepare(adapter, store)
    assert {:error, _} = resolve(adapter, store, child, :absent, 1303)
    assert {:ok, pending} = accept(adapter, store, child, 1303)
    saved = pending.branch.native_authority.deletion
    assert pending.state == :unknown and pending.operation == :delete and saved.proof == nil
    assert saved.version == child.version and saved.delete_version == elem(child.last_request, 1)
    assert fetch(adapter, store, parent) == parent
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    roundtrip(pending)
    proof = proof(saved.request)

    for invalid <- [
          :absent,
          BranchDeletionResolution.to_wire(proof),
          %{proof | deletion_sha256: String.duplicate("b", 64)}
        ] do
      assert {:error, _} = resolve(adapter, store, pending, invalid, 1304)
      assert fetch(adapter, store, pending) == pending
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:ok, fresh} =
             adapter.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1304, 10_000])

    assert {:error, _} = resolve(adapter, store, pending, proof, 1305)
    assert {:ok, ^fresh} = accept(adapter, store, fresh, 1305)
    assert fresh.branch.native_authority.deletion.request == saved.request
    assert {:ok, gone} = resolve(adapter, store, fresh, proof, 1305)

    assert Map.take(gone, [:state, :operation, :phase, :reservation]) == %{
             state: :deleted,
             operation: nil,
             phase: nil,
             reservation: nil
           }

    assert gone.branch.state == :held
    assert gone.branch.native_authority.deletion.proof == proof

    assert gone.created_machine == child.created_machine
    assert gone.observed_machine == child.observed_machine

    assert gone.last_request == child.last_request
    assert fetch(adapter, store, parent) == parent
    assert parent.branch_children[child.id] == false
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^gone} = resolve(adapter, store, gone, proof, 1306)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    roundtrip(gone)
    {parent, gone, proof, expected}
  end

  def roundtrip(child) do
    assert {:ok, <<"smolbox-record-v34\0", body::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)

    for version <- 1..33,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v34\0" <> :erlang.term_to_binary(child, compressed: 9))

    bytes
  end
end
