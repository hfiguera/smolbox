defmodule SmolBox.Store.NativeBranchReleaseContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchReleaseTransition,
    Identity,
    NativeBranchReleaseResult,
    NativeGrowth
  }

  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, Contract, NativeBranchContract, NativeBranchReleaseOps}

  def prepare(adapter, store) do
    {parent, child, _, usage} = NativeBranchContract.complete(adapter, store, true)

    assert {:ok, accepted} =
             adapter.machine(store, :branch_release, [
               ManagedMachine.key(child),
               child.version,
               1200
             ])

    assert {:ok, pending} =
             adapter.machine(store, :claim, [ManagedMachine.key(accepted), "owner", 1200, 10_000])

    assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert parent.active_branch == child.id and pending.branch.state == :release_pending

    assert pending.branch.native_authority.release.source ==
             parent.observed_machine.backend_identity.receipt

    assert pending.branch.native_authority.release.child ==
             child.observed_machine.backend_identity.receipt

    assert pending.created_machine == child.created_machine
    assert pending.branch.native_authority.completion == child.branch.native_authority.completion

    assert {:ok, ^pending} =
             adapter.machine(store, :branch_release, [
               ManagedMachine.key(child),
               child.version,
               1201
             ])

    assert {:error, _} =
             adapter.machine(store, :branch_release, [
               ManagedMachine.key(child),
               pending.version,
               1201
             ])

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    {parent, pending, result(parent, pending), usage}
  end

  # Synthetic canonical explicit proof. No manager, SDK mutation or VM exists.
  def result(parent, child) do
    release = child.branch.native_authority.release
    completion = child.branch.native_authority.completion

    [_, row] =
      "../../../native/smolbox-protocol/fixtures/branch-creation-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    template = row["completion"]["release"]

    change = %{
      template["change"]
      | "mode" => "explicit",
        "binding" => completion.publication["change"]["child_origin"],
        "request" => release.request,
        "identity_sha256" => completion.identity_sha256
    }

    material = %{
      template["receipt"]["material"]
      | "operation_id" => release.request["operation_id"],
        "request_sha256" => release.request["request_sha256"]
    }

    material = %{
      material
      | "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-branch-child-release-v1",
            BranchCanonical.ordered(release.child, :receipt),
            BranchCanonical.ordered(change, :release_change),
            material["record_sha256"]
          ])
    }

    wire = %{
      template
      | "previous" => release.child,
        "receipt" => Map.put(release.child, "material", material),
        "change" => change
    }

    assert {:ok, proof} = BranchReleaseTransition.from_wire(wire)

    observed = %{
      child.observed_machine
      | backend_identity: %Identity{
          receipt: proof.receipt,
          transition: proof,
          material_history: [proof],
          pid_identity: release.child_pid
        }
    }

    result = %NativeBranchReleaseResult{
      transition: proof,
      source: parent.observed_machine,
      child: observed
    }

    assert NativeBranchReleaseResult.bound?(result, child.branch.native_authority)
    result
  end

  def advance(adapter, store, child, action, now) do
    adapter.machine(store, :branch_release_advance, [
      ManagedMachine.key(child),
      Contract.guard(child),
      child.branch.state,
      action,
      now
    ])
  end

  def completed(adapter, store, uncertain \\ false) do
    {parent, pending, result, usage} = prepare(adapter, store)

    assert {:error, _} =
             NativeBranchReleaseOps.advance(
               parent,
               pending,
               :release_pending,
               :dispatching,
               pending.branch.deadline_ms + 1
             )

    for record <- [parent, pending], do: roundtrip(record, record == pending)
    assert {:error, _} = advance(adapter, store, pending, {:native_complete, result}, 1201)
    assert {:ok, sent} = advance(adapter, store, pending, :dispatching, 1201)
    assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])

    assert {:error, _} =
             NativeBranchReleaseOps.advance(
               parent,
               sent,
               :release_dispatching,
               {:native_complete, result},
               sent.branch.deadline_ms + 1
             )

    assert {:error, _} = advance(adapter, store, pending, :unknown, 1202)

    for invalid <- [
          result.child,
          %{result | source: :absent},
          %{result | child: :absent},
          put_in(result.child.backend_identity.pid_identity, [234, 568]),
          put_in(result.source.backend_identity.pid_identity, [123, 457]),
          put_in(
            result.transition.change["request"]["request_sha256"],
            String.duplicate("0", 64)
          ),
          put_in(result.child.backend_identity.material_history, nil),
          put_in(result.child.cpus, 2),
          put_in(result.source.storage_gb, 2)
        ] do
      assert {:error, _} = advance(adapter, store, sent, {:native_complete, invalid}, 1202)
      assert {:ok, ^sent} = adapter.machine(store, :fetch, [ManagedMachine.key(sent)])
      assert {:ok, ^parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    saved =
      if uncertain do
        assert {:ok, unknown} = advance(adapter, store, sent, :unknown, 1202)
        assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
        assert parent.state == :unknown and unknown.state == :unknown
        assert {:error, _} = advance(adapter, store, unknown, {:native_complete, result}, 1203)

        assert {:error, _} =
                 adapter.machine(store, :branch_resolve, [
                   ManagedMachine.key(parent),
                   Contract.guard(parent),
                   unknown.id,
                   result.source,
                   result.child,
                   1203
                 ])

        assert {:ok, saved} =
                 adapter.machine(store, :branch_resolve, [
                   ManagedMachine.key(parent),
                   Contract.guard(parent),
                   unknown.id,
                   result.source,
                   result,
                   1203
                 ])

        saved
      else
        assert {:ok, saved} = advance(adapter, store, sent, {:native_complete, result}, 1202)
        saved
      end

    assert {:ok, source} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:released, :running} == {saved.branch.state, saved.state}
    assert saved.created_machine == pending.created_machine
    assert source.active_branch == nil and source.operation == nil and source.state == :running

    assert source.created_machine == parent.created_machine and
             source.native_branch_history == parent.native_branch_history

    assert saved.branch.native_authority.release.transition == result.transition
    assert saved.branch.native_authority.completion == pending.branch.native_authority.completion

    assert {:ok, ^saved} =
             adapter.machine(store, :branch_release, [
               ManagedMachine.key(saved),
               pending.branch.release_version,
               1204
             ])

    assert {:error, _} =
             adapter.machine(store, :branch_release, [
               ManagedMachine.key(saved),
               saved.version,
               1204
             ])

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, receipt, _, proof} = NativeGrowth.head(saved)
    assert receipt == result.transition.receipt and proof == result.transition
    assert {:ok, [^proof]} = NativeGrowth.transitions(saved)
    roundtrip(saved, true)
    {source, saved, result, usage}
  end

  def roundtrip(record, new?) do
    assert {:ok, bytes} = Codec.encode(record)
    [prefix, body] = :binary.split(bytes, <<0>>)
    assert prefix == if(new?, do: "smolbox-record-v31", else: "smolbox-record-v30")
    assert {:ok, ^record} = Codec.decode(bytes)

    if new? do
      for version <- 1..30,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

      assert {:error, _} = Codec.decode(bytes <> "tail")

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v31\0" <> :erlang.term_to_binary(record, compressed: 9)
               )
    end
  end
end
