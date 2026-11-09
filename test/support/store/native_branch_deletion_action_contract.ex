defmodule SmolBox.Store.NativeBranchDeletionActionContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchDeletionCollection,
    BranchDeletionContinuation,
    BranchDeletionResolution,
    NativeBranchDeletionAction
  }

  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    Contract,
    NativeBranchDeletionContract
  }

  def accept(adapter, store, child, action, now),
    do:
      adapter.machine(store, :branch_delete_action_accept, [
        ManagedMachine.key(child),
        Contract.guard(child),
        action,
        now
      ])

  def finish(adapter, store, child, action, proof, now),
    do:
      adapter.machine(store, :branch_delete_action_complete, [
        ManagedMachine.key(child),
        Contract.guard(child),
        action,
        proof,
        now
      ])

  def saved(child, action),
    do: Map.fetch!(child.branch.native_authority, NativeBranchDeletionAction.field(action))

  def proof(request) when not is_map_key(request, "action") do
    value = %{
      "schema" => 1,
      "child" => request["child"],
      "operation_id" => request["operation_id"],
      "request_sha256" => request["request_sha256"],
      "completion_sha256" =>
        BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)),
      "deletion_sha256" => String.duplicate("a", 64),
      "collection_sha256" => String.duplicate("b", 64)
    }

    value =
      if request["release"],
        do:
          Map.put(
            value,
            "release_sha256",
            BranchCanonical.digest(BranchCanonical.ordered(request["release"], :child_release))
          ),
        else: value

    value = Map.put(value, "proof_sha256", BranchDeletionCollection.proof_digest(value))
    assert {:ok, proof} = BranchDeletionCollection.from_wire(value)
    assert BranchDeletionCollection.matches?(proof, request)
    proof
  end

  def proof(request) do
    {module, domain} =
      if request["action"] == "continue",
        do: {BranchDeletionContinuation, "smolbox-held-child-delete-continuation-proof-v1"},
        else: {BranchDeletionResolution, "smolbox-held-child-delete-resolution-v1"}

    deletion = String.duplicate("a", 64)

    struct!(module,
      schema: 1,
      child: request["child"],
      operation_id: request["operation_id"],
      request_sha256: request["request_sha256"],
      deletion_sha256: deletion,
      proof_sha256:
        BranchCanonical.digest([
          domain,
          1,
          BranchCanonical.ordered(request["child"], :receipt),
          request["operation_id"],
          request["request_sha256"],
          deletion
        ])
    )
  end

  def complete(adapter, store, action) do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store)
    assert {:ok, pending} = accept(adapter, store, child, action, 1303)
    frozen = saved(pending, action)
    assert frozen.version == child.version
    assert frozen.delete_version == elem(child.last_request, 1)
    assert frozen.proof == nil
    assert NativeBranchDeletionAction.valid?(frozen, pending.branch.native_authority, action)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^pending} = accept(adapter, store, pending, action, 1304)
    roundtrip(pending)
    proof = proof(frozen.request)
    wrong_action = if action == :continue, do: :cleanup, else: :continue

    different_request =
      NativeBranchDeletionAction.intent(
        pending.branch.native_authority,
        action,
        frozen.version + 1,
        frozen.delete_version,
        frozen.request["child"]
      )

    reject_changes(
      adapter,
      store,
      {pending, parent, usage},
      {action, wrong_action},
      proof,
      proof(different_request)
    )

    assert {:error, _} =
             NativeBranchDeletionContract.resolve(adapter, store, pending, proof, 1304)

    assert {:ok, fresh} =
             adapter.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1304, 10_000])

    assert {:error, _} = finish(adapter, store, pending, action, proof, 1305)
    assert {:ok, ^fresh} = accept(adapter, store, fresh, action, 1305)
    assert saved(fresh, action) == frozen
    assert {:ok, gone} = finish(adapter, store, fresh, action, proof, 1305)
    assert gone.state == :deleted and gone.reservation == nil and ManagedMachine.idle?(gone)
    assert gone.reserved_ports == [] and gone.branch.state == :held
    assert saved(gone, action).proof == proof
    assert gone.created_machine == child.created_machine
    assert gone.observed_machine == child.observed_machine
    assert gone.last_request == child.last_request
    assert gone.branch.native_authority.deletion == nil
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    assert parent.branch_children[child.id] == false
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^gone} = finish(adapter, store, gone, action, proof, 1306)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert {:error, _} = accept(adapter, store, gone, wrong_action, 1306)
    roundtrip(gone)
    {parent, gone, proof, expected}
  end

  def roundtrip(child) do
    assert {:ok, <<"smolbox-record-v35\0", body::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)

    for version <- 1..34,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v35\0" <> :erlang.term_to_binary(child, compressed: 9))

    bytes
  end

  def reject_changes(
        adapter,
        store,
        {pending, parent, usage},
        {action, wrong_action},
        proof,
        foreign_proof
      ) do
    raw = Map.new(Map.from_struct(proof), fn {k, v} -> {Atom.to_string(k), v} end)

    for {kind, invalid} <- [
          {action, :absent},
          {action, raw},
          {action, foreign_proof},
          {action, %{proof | deletion_sha256: String.duplicate("0", 64)}},
          {wrong_action, proof}
        ] do
      assert {:error, _} = finish(adapter, store, pending, kind, invalid, 1304)
      assert NativeBranchDeletionContract.fetch(adapter, store, pending) == pending
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end
  end
end
