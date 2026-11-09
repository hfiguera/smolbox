defmodule SmolBox.Store.NativeBranchSiblingContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{BranchSpec, ManagedMachine, Profile}
  alias SmolBox.Embedded.NativeBranchRetirement

  alias SmolBox.Store.{
    Codec,
    Contract,
    MachineOps,
    NativeBranchBackingContract,
    NativeBranchContract,
    NativeBranchReleaseContract,
    NativeBranchRetirementContract
  }

  @capacity %{slots: 16, cpus: 32, memory_mb: 65_536, disk_gb: 1024}

  # Synthetic native proofs drive the actual paired store operations. No SDK
  # manager, VM, process enrollment or native package qualification is supplied.
  def complete(adapter, store, first_mode, second_mode, reverse) do
    {parent, first, _, _} =
      if first_mode == :released,
        do: NativeBranchReleaseContract.completed(adapter, store),
        else: NativeBranchContract.complete(adapter, store, first_mode == :held)

    immutable_source = parent.created_machine
    original_first = first
    {parent, second} = sibling(adapter, store, parent, first, second_mode)
    assert fetch(adapter, store, first) == original_first
    assert parent.created_machine == immutable_source
    assert parent.branch_children == %{first.id => false, second.id => false}

    assert Map.keys(parent.native_branch_history) |> Enum.sort() ==
             Enum.sort([first.id, second.id])

    assert parent.native_branch_history[second.id].previous ==
             parent.native_branch_history[first.id].receipt

    assert {:ok, usage} = adapter.usage(store, parent.worker_id)
    expected = add(Profile.resources(parent.spec.profile), allocation(first))
    assert usage == add(expected, allocation(second))
    unchanged_history = parent.native_branch_history
    children = if reverse, do: [second, first], else: [first, second]

    {parent, retired, usage} =
      Enum.reduce(Stream.with_index(children), {parent, [], usage}, fn {child, index},
                                                                       {source, prior, charges} ->
        now = 1600 + index * 10
        sibling = if child.id == first.id, do: second, else: first
        sibling = fetch(adapter, store, sibling)
        assert {:error, _} = MachineOps.request(source, :stop, source.version, now)
        gone = delete(adapter, store, child, now)
        charges = subtract(charges, Profile.resources(child.spec.profile))
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)
        proof = NativeBranchRetirementContract.proof(gone)

        assert {:error, _} =
                 NativeBranchRetirementContract.advance(
                   adapter,
                   store,
                   source,
                   gone,
                   sibling_proof(sibling),
                   now + 3
                 )

        assert fetch(adapter, store, source) == source
        assert fetch(adapter, store, gone) == gone
        assert fetch(adapter, store, sibling) == sibling
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)

        assert {:ok, retired} =
                 NativeBranchRetirementContract.advance(
                   adapter,
                   store,
                   source,
                   gone,
                   proof,
                   now + 3
                 )

        source = fetch(adapter, store, source)
        assert source.branch_children[child.id] == true
        assert source.branch_children[sibling.id] == (index == 1)
        assert source.native_branch_history == unchanged_history
        assert source.created_machine == immutable_source
        assert fetch(adapter, store, sibling) == sibling
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)

        assert {:error, _} =
                 NativeBranchBackingContract.accept(adapter, store, source, retired, now + 4)

        assert {:ok, ^retired} =
                 NativeBranchRetirementContract.advance(
                   adapter,
                   store,
                   source,
                   retired,
                   proof,
                   now + 4
                 )

        assert fetch(adapter, store, source) == source

        roundtrip([source, retired, sibling])
        {source, prior ++ [retired], charges}
      end)

    assert {:ok, _} = MachineOps.request(parent, :stop, parent.version, 1700)
    parent = delete(adapter, store, parent, 1700)
    usage = subtract(usage, Profile.resources(parent.spec.profile))
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)

    {parent, pending} =
      Enum.reduce(Stream.with_index(retired), {parent, []}, fn {child, index}, {source, prior} ->
        assert {:ok, accepted} =
                 NativeBranchBackingContract.accept(adapter, store, source, child, 1704 + index)

        assert {:ok, ^usage} = adapter.usage(store, source.worker_id)
        {fetch(adapter, store, source), prior ++ [accepted]}
      end)

    {parent, closed, usage} =
      Enum.reduce(Stream.with_index(pending), {parent, [], usage}, fn {child, index},
                                                                      {source, prior, charges} ->
        now = 1710 + index * 10
        others = Enum.reject(pending, &(&1.id == child.id))
        others = Enum.map(others, &fetch(adapter, store, &1))
        [other] = others
        proof = NativeBranchBackingContract.proof(child.branch.native_authority.backing.request)
        crossed = NativeBranchBackingContract.proof(other.branch.native_authority.backing.request)

        assert {:error, _} =
                 NativeBranchBackingContract.complete_proof(
                   adapter,
                   store,
                   source,
                   child,
                   crossed,
                   now
                 )

        assert fetch(adapter, store, source) == source
        assert fetch(adapter, store, child) == child
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)

        assert {:ok, closed} =
                 NativeBranchBackingContract.complete_proof(
                   adapter,
                   store,
                   source,
                   child,
                   proof,
                   now + 1
                 )

        source = fetch(adapter, store, source)
        charges = subtract(charges, child.branch.spec.policy.resources)
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)
        for other <- others, do: assert(fetch(adapter, store, other) == other)
        assert source.native_branch_history == unchanged_history
        assert source.created_machine == immutable_source

        assert {:ok, ^closed} =
                 NativeBranchBackingContract.complete_proof(
                   adapter,
                   store,
                   source,
                   closed,
                   proof,
                   now + 2
                 )

        assert fetch(adapter, store, source) == source
        assert {:ok, ^charges} = adapter.usage(store, source.worker_id)
        roundtrip([source, closed | others])
        {source, prior ++ [closed], charges}
      end)

    assert usage == %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}
    assert Enum.all?(closed, &(&1.branch.state == :closed))
    roundtrip([parent | closed])
    {parent, closed}
  end

  defp sibling(adapter, store, parent, first, mode) do
    {:ok, spec} =
      BranchSpec.new(
        id: "sibling",
        policy: first.branch.spec.policy,
        idle: true,
        hold: mode != :ready
      )

    fingerprint =
      BranchSpec.fingerprint(spec, ManagedMachine.key(parent), String.duplicate("k", 32))

    assert {:ok, child} =
             adapter.machine(store, :branch_accept, [
               ManagedMachine.key(parent),
               spec,
               fingerprint,
               "owned-sibling",
               @capacity,
               1400
             ])

    parent = fetch(adapter, store, parent)
    result = NativeBranchContract.result(parent, child)
    result = put_in(result.child.backend_identity.pid_identity, [345, 678])

    assert {:ok, sent} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               child,
               :accepted,
               :dispatching,
               1401
             )

    parent = fetch(adapter, store, parent)

    assert {:ok, child} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               sent,
               :dispatching,
               {:native_complete, result},
               1402
             )

    if mode == :released do
      assert {:ok, child} =
               adapter.machine(store, :branch_release, [
                 ManagedMachine.key(child),
                 child.version,
                 1500
               ])

      assert {:ok, child} =
               adapter.machine(store, :claim, [ManagedMachine.key(child), "owner", 1500, 10_000])

      parent = fetch(adapter, store, parent)
      result = NativeBranchReleaseContract.result(parent, child)

      assert {:ok, sent} =
               NativeBranchReleaseContract.advance(adapter, store, child, :dispatching, 1501)

      assert {:ok, child} =
               NativeBranchReleaseContract.advance(
                 adapter,
                 store,
                 sent,
                 {:native_complete, result},
                 1502
               )

      {fetch(adapter, store, parent), child}
    else
      {fetch(adapter, store, parent), child}
    end
  end

  defp delete(adapter, store, record, now) do
    assert {:ok, claimed} =
             adapter.machine(store, :claim, [ManagedMachine.key(record), "owner", now, 10_000])

    assert {:ok, deleting} =
             adapter.machine(store, :request, [
               ManagedMachine.key(record),
               :delete,
               claimed.version,
               now + 1
             ])

    assert {:ok, gone} =
             adapter.machine(store, :write, [
               ManagedMachine.key(record),
               Contract.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: now + 2
               ],
               now + 2
             ])

    gone
  end

  defp fetch(adapter, store, record),
    do: NativeBranchBackingContract.fetch(adapter, store, record)

  defp allocation(child),
    do: add(Profile.resources(child.spec.profile), child.branch.spec.policy.resources)

  defp sibling_proof(sibling) do
    sibling.branch.native_authority
    |> NativeBranchRetirement.intent(
      sibling.version,
      sibling.observed_machine.backend_identity.receipt
    )
    |> NativeBranchRetirementContract.proof_from_request()
  end

  defp add(a, b), do: Map.merge(a, b, fn _, x, y -> x + y end)
  defp subtract(a, b), do: Map.merge(a, b, fn _, x, y -> x - y end)

  defp roundtrip(records) do
    for record <- records do
      assert :ok = ManagedMachine.validate(record)
      assert {:ok, bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end
  end
end
