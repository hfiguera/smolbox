defmodule SmolBox.Store.NativeReleasedBranchCleanupContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    NativeBranchDeletionAction,
    NativeReleasedBranchDeletionCleanup,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    NativeBranchDeletionContract,
    NativeReleasedBranchContinuationContract,
    NativeReleasedBranchDeletionContract
  }

  alias SmolBox.Store.NativeBranchDeletionActionContract, as: ActionContract

  def proof(request) do
    deletion = String.duplicate("a", 64)

    struct!(ReleasedBranchDeletionResolution,
      schema: 1,
      child: request["child"],
      operation_id: request["operation_id"],
      request_sha256: request["request_sha256"],
      completion_sha256:
        BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)),
      release_sha256:
        BranchCanonical.digest(BranchCanonical.ordered(request["release"], :child_release)),
      deletion_sha256: deletion,
      proof_sha256:
        BranchCanonical.digest([
          "smolbox-released-child-delete-resolution-v1",
          1,
          BranchCanonical.ordered(request["child"], :receipt),
          request["operation_id"],
          request["request_sha256"],
          BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)),
          BranchCanonical.digest(BranchCanonical.ordered(request["release"], :child_release)),
          deletion
        ])
    )
  end

  def complete(adapter, store, mode) do
    action = :cleanup
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store, mode)
    assert {:ok, pending} = ActionContract.accept(adapter, store, child, action, 1303)
    frozen = ActionContract.saved(pending, action)
    assert frozen.version == child.version
    assert frozen.delete_version == elem(child.last_request, 1)
    assert frozen.proof == nil
    assert NativeBranchDeletionAction.valid?(frozen, pending.branch.native_authority, action)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^pending} = ActionContract.accept(adapter, store, pending, action, 1304)
    roundtrip(pending)
    proof = proof(frozen.request)
    wrong_action = :continue

    different_request =
      NativeReleasedBranchDeletionCleanup.intent(
        pending.branch.native_authority,
        action,
        frozen.version + 1,
        frozen.delete_version,
        frozen.request["child"]
      )

    ActionContract.reject_changes(
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

    assert {:error, _} = ActionContract.finish(adapter, store, pending, action, proof, 1305)
    assert {:ok, ^fresh} = ActionContract.accept(adapter, store, fresh, action, 1305)
    assert ActionContract.saved(fresh, action) == frozen
    assert {:ok, gone} = ActionContract.finish(adapter, store, fresh, action, proof, 1305)
    assert gone.state == :deleted and gone.reservation == nil and ManagedMachine.idle?(gone)
    assert gone.reserved_ports == [] and gone.branch.state == child.branch.state
    assert ActionContract.saved(gone, action).proof == proof
    assert gone.created_machine == child.created_machine
    assert gone.observed_machine == child.observed_machine
    assert gone.last_request == child.last_request
    assert gone.branch.native_authority.deletion == nil
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    assert parent.branch_children[child.id] == false
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert {:ok, ^gone} = ActionContract.finish(adapter, store, gone, action, proof, 1306)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    assert {:error, _} = ActionContract.accept(adapter, store, gone, wrong_action, 1306)
    roundtrip(gone)
    {parent, gone, proof, expected}
  end

  def roundtrip(child) do
    assert {:ok, <<"smolbox-record-v42\0", body::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)

    for version <- 1..41,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v42\0" <> :erlang.term_to_binary(child, compressed: 9))

    bytes
  end

  def interleaved(adapter, store, mode, route) when route in [:continue, :resolve, :cleanup] do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store, mode)
    assert {:ok, child} = ActionContract.accept(adapter, store, child, :cleanup, 1303)
    cleanup = child.branch.native_authority.delete_cleanup
    assert {:ok, child} = ActionContract.accept(adapter, store, child, :continue, 1304)
    continued = child.branch.native_authority.delete_continuation
    assert {:ok, child} = NativeReleasedBranchDeletionContract.accept(adapter, store, child, 1305)
    observed = child.branch.native_authority.deletion

    # Positive absence shares a proof type, but neither observation grant can
    # authorize the other's completion or an SDK-success continuation.
    cleanup_proof = proof(cleanup.request)
    observed_proof = NativeReleasedBranchDeletionContract.proof(observed.request)

    continued_proof =
      NativeReleasedBranchContinuationContract.proof(continued.request)

    for {action, invalid} <- [
          {:cleanup, observed_proof},
          {:cleanup, continued_proof},
          {:continue, cleanup_proof}
        ],
        do:
          assert(
            {:error, _} = ActionContract.finish(adapter, store, child, action, invalid, 1306)
          )

    assert {:error, _} =
             NativeReleasedBranchDeletionContract.resolve(
               adapter,
               store,
               child,
               cleanup_proof,
               1306
             )

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    roundtrip(child)

    result =
      case route do
        :continue ->
          ActionContract.finish(adapter, store, child, :continue, continued_proof, 1306)

        :cleanup ->
          ActionContract.finish(adapter, store, child, :cleanup, cleanup_proof, 1306)

        :resolve ->
          NativeReleasedBranchDeletionContract.resolve(
            adapter,
            store,
            child,
            observed_proof,
            1306
          )
      end

    assert {:ok, gone} = result

    for {slot, original, expected} <- [
          {:delete_cleanup, cleanup, :cleanup},
          {:delete_continuation, continued, :continue},
          {:deletion, observed, :resolve}
        ] do
      current = Map.fetch!(gone.branch.native_authority, slot)
      assert %{current | proof: nil} == original
      assert not is_nil(current.proof) == (route == expected)
    end

    for {action, proof} <- [{:cleanup, cleanup_proof}, {:continue, continued_proof}],
        action != route,
        do: assert({:error, _} = ActionContract.finish(adapter, store, gone, action, proof, 1307))

    if route != :resolve,
      do:
        assert(
          {:error, _} =
            NativeReleasedBranchDeletionContract.resolve(
              adapter,
              store,
              gone,
              observed_proof,
              1307
            )
        )

    assert :ok = ManagedMachine.validate(gone)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    roundtrip(gone)
    gone
  end
end
