defmodule SmolBox.Store.NativeBranchBackingContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.Embedded.{BranchBackingRelease, BranchCanonical}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, Contract, NativeBranchRetirementContract}

  def prepare(adapter, store, mode) do
    {source, child, _, _} = NativeBranchRetirementContract.complete(adapter, store, mode)

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(source),
               :delete,
               source.version,
               1310
             ])

    assert {:ok, source} =
             adapter.machine(store, :write, [
               ManagedMachine.key(source),
               Contract.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: 1311
               ],
               1311
             ])

    assert {:ok, usage} = adapter.usage(store, source.worker_id)
    {source, child, usage}
  end

  def accept(adapter, store, source, child, now, removed \\ true),
    do:
      adapter.machine(store, :branch_backing_accept, [
        ManagedMachine.key(source),
        Contract.guard(source),
        child.id,
        child.version,
        removed,
        now
      ])

  def complete_proof(adapter, store, source, child, proof, now),
    do:
      adapter.machine(store, :branch_release_storage, [
        ManagedMachine.key(source),
        Contract.guard(source),
        child.id,
        proof,
        now
      ])

  def fetch(adapter, store, record) do
    assert {:ok, current} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
    current
  end

  # Entirely synthetic receipt algebra, never native ownership or VM evidence.
  def proof(request) do
    proof = proof(request, request["completion"]["publication"])
    assert BranchBackingRelease.matches?(proof, request)
    proof
  end

  def proof(request, publication) do
    plan = get_in(publication, ~w(change child_origin intent plan))
    bytes = (plan["ordinary_child"]["disk_gb"] + plan["minimum_extra_disk_gb"]) * 1_073_741_824

    %BranchBackingRelease{
      schema: 1,
      publication: publication,
      operation_id: request["operation_id"],
      request_sha256: request["request_sha256"],
      native_bytes: bytes,
      proof_sha256:
        BranchCanonical.digest([
          "smolbox-branch-backing-release-v1",
          1,
          BranchCanonical.ordered(publication, :publication),
          request["operation_id"],
          request["request_sha256"],
          bytes
        ])
    }
  end

  def completed(adapter, store, mode) do
    {source, child, usage} = prepare(adapter, store, mode)
    assert {:error, _} = accept(adapter, store, source, child, 1312, false)

    assert {:error, _} =
             accept(adapter, store, source, %{child | version: child.version + 1}, 1312)

    assert {:error, _} =
             adapter.machine(store, :branch_release_storage, [
               ManagedMachine.key(source),
               Contract.guard(source),
               child.id,
               1312
             ])

    assert {:ok, pending} = accept(adapter, store, source, child, 1312)

    assert pending.branch.state == :retired and
             pending.branch.native_authority.backing.proof == nil

    assert pending.branch.native_authority.backing.version == child.version
    assert pending.branch.native_authority.retirement == child.branch.native_authority.retirement
    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    roundtrip(pending)
    parent = fetch(adapter, store, source)
    assert {:error, _} = accept(adapter, store, source, pending, 1313)
    assert {:ok, ^pending} = accept(adapter, store, parent, pending, 1313)
    assert fetch(adapter, store, parent) == parent
    request = pending.branch.native_authority.backing.request
    proof = proof(request)

    for wrong <- [
          :absent,
          BranchBackingRelease.to_wire(proof),
          %{proof | native_bytes: proof.native_bytes + 1}
        ] do
      assert {:error, _} = complete_proof(adapter, store, parent, pending, wrong, 1313)
      assert fetch(adapter, store, pending) == pending and fetch(adapter, store, parent) == parent
      assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    end

    # Ordinary claim/version changes must not mint a different backing request.
    assert {:ok, current_child} =
             adapter.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1314, 10_000])

    assert {:ok, current_parent} =
             adapter.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1314, 10_000])

    assert current_child.branch.native_authority.backing.request == request
    assert {:error, _} = complete_proof(adapter, store, parent, current_child, proof, 1315)

    assert {:ok, closed} =
             complete_proof(adapter, store, current_parent, current_child, proof, 1315)

    assert closed.branch.state == :closed and
             closed.branch.native_authority.backing.proof == proof

    assert closed.created_machine == child.created_machine and
             closed.observed_machine == child.observed_machine

    expected_usage = Map.merge(usage, child.branch.spec.policy.resources, fn _, a, b -> a - b end)
    assert {:ok, ^expected_usage} = adapter.usage(store, source.worker_id)
    current_parent = fetch(adapter, store, current_parent)
    assert current_parent.native_branch_history == source.native_branch_history
    assert {:ok, ^closed} = complete_proof(adapter, store, current_parent, closed, proof, 1316)
    assert {:ok, ^expected_usage} = adapter.usage(store, source.worker_id)
    roundtrip(closed)
    {current_parent, closed, proof, expected_usage}
  end

  def roundtrip(child) do
    assert {:ok, <<"smolbox-record-v33\0", body::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)

    for version <- 1..32,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v33\0" <> :erlang.term_to_binary(child, compressed: 9))

    bytes
  end
end
