defmodule SmolBox.Store.NativeUnbootedBranchBackingContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
    BranchPublication,
    NativeBranchBacking,
    UnbootedBranchBackingRelease,
    UnbootedBranchDisposal
  }

  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Contract,
    NativeBranchBackingContract,
    NativeUnbootedBranchRetirementContract
  }

  def prepare(adapter, store, hold, provenance \\ "deleted") do
    {parent, child, _, _} =
      NativeUnbootedBranchRetirementContract.complete(adapter, store, hold, provenance)

    assert {:ok, <<"smolbox-record-v38", 0, _::binary>> = before} = Codec.encode(child)

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(parent),
               :delete,
               parent.version,
               1310
             ])

    assert {:ok, source} =
             adapter.machine(store, :write, [
               ManagedMachine.key(parent),
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
    assert usage == child.branch.spec.policy.resources
    assert {:ok, ^child} = Codec.decode(before)
    assert {:ok, ^before} = Codec.encode(child)
    {source, child, usage}
  end

  defdelegate accept(adapter, store, parent, child, now, removed \\ true),
    to: NativeBranchBackingContract

  defdelegate complete_proof(adapter, store, parent, child, proof, now),
    to: NativeBranchBackingContract

  defdelegate fetch(adapter, store, record), to: NativeBranchBackingContract

  # Synthetic native accounting acknowledgement. No filesystem deletion or SDK
  # operation occurs; ordinary platform qualification remains separate.
  def proof(request) do
    publication = get_in(request, ~w(disposal publication))
    plan = get_in(publication, ~w(change child_origin intent plan))
    bytes = (plan["ordinary_child"]["disk_gb"] + plan["minimum_extra_disk_gb"]) * 1_073_741_824

    proof = %BranchBackingRelease{
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

    assert UnbootedBranchBackingRelease.matches?(proof, request)
    proof
  end

  def completed(adapter, store, hold, provenance \\ "deleted") do
    {source, child, usage} = prepare(adapter, store, hold, provenance)
    assert {:error, _} = accept(adapter, store, source, child, 1312, false)

    assert {:error, _} =
             accept(adapter, store, source, %{child | version: child.version + 1}, 1312)

    assert {:ok, pending} = accept(adapter, store, source, child, 1312)
    source = fetch(adapter, store, source)
    saved = pending.branch.native_authority.backing
    assert pending.branch.state == :backing_pending and saved.proof == nil

    assert saved.version == child.version and
             saved.version > child.branch.native_authority.retirement.version

    assert saved.request["disposal"] ==
             UnbootedBranchDisposal.to_wire(child.branch.native_authority.disposal.proof)

    assert NativeBranchBacking.unbooted?(pending)
    assert pending.branch.native_authority.retirement == child.branch.native_authority.retirement
    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    roundtrip(pending)
    ack = proof(saved.request)

    assert {:error, _} =
             complete_proof(
               adapter,
               store,
               source,
               pending,
               BranchBackingRelease.to_wire(ack),
               1313
             )

    assert {:error, _} =
             complete_proof(
               adapter,
               store,
               source,
               pending,
               %{ack | native_bytes: ack.native_bytes + 1},
               1313
             )

    assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
    assert {:ok, closed} = complete_proof(adapter, store, source, pending, ack, 1313)
    source = fetch(adapter, store, source)
    assert closed.branch.state == :closed and closed.state == :deleted
    assert closed.branch.native_authority.backing == %{saved | proof: ack}
    assert closed.branch.native_authority.disposal == child.branch.native_authority.disposal
    assert closed.branch.native_authority.retirement == child.branch.native_authority.retirement

    assert closed.created_machine == nil and closed.observed_machine == nil and
             closed.branch.native_authority.completion == nil

    assert source.branch_children == %{child.id => true}

    assert {:ok, publication} = BranchPublication.from_wire(ack.publication)
    assert source.native_branch_history[child.id] == publication

    assert {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
             adapter.usage(store, source.worker_id)

    assert {:ok, ^closed} = complete_proof(adapter, store, source, closed, ack, 1314)
    roundtrip(closed)
    {source, closed, ack}
  end

  def roundtrip(record) do
    assert {:ok, <<"smolbox-record-v39", 0, body::binary>> = encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)

    for version <- 1..38,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> body))

    assert {:error, _} = Codec.decode(encoded <> "tail")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v39" <> <<0>> <> :erlang.term_to_binary(record, compressed: 9)
             )

    encoded
  end
end
