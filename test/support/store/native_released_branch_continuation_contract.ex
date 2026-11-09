defmodule SmolBox.Store.NativeReleasedBranchContinuationContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    NativeBranchDeletionAction,
    NativeReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionContinuation
  }

  alias SmolBox.{ManagedMachine, Profile}

  alias SmolBox.Store.{
    Codec,
    NativeBranchDeletionContract,
    NativeReleasedBranchDeletionContract
  }

  alias SmolBox.Store.NativeBranchDeletionActionContract, as: ActionContract

  def proof(request) do
    deletion = String.duplicate("a", 64)

    struct!(ReleasedBranchDeletionContinuation,
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
          "smolbox-released-child-delete-continuation-proof-v1",
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
    action = :continue
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
    wrong_action = :cleanup

    different_request =
      NativeReleasedBranchDeletionContinuation.intent(
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
    assert {:ok, <<"smolbox-record-v41\0", body::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)

    for version <- 1..40,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v41\0" <> :erlang.term_to_binary(child, compressed: 9))

    bytes
  end

  def interleaved(adapter, store, mode, route) when route in [:continue, :resolve] do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(adapter, store, mode)
    assert {:ok, child} = ActionContract.accept(adapter, store, child, :continue, 1303)
    continued = child.branch.native_authority.delete_continuation
    assert {:ok, child} = NativeReleasedBranchDeletionContract.accept(adapter, store, child, 1304)
    observed = child.branch.native_authority.deletion

    gone =
      case route do
        :continue ->
          assert {:ok, gone} =
                   ActionContract.finish(
                     adapter,
                     store,
                     child,
                     :continue,
                     proof(continued.request),
                     1305
                   )

          assert gone.branch.native_authority.deletion == observed
          gone

        :resolve ->
          assert {:ok, gone} =
                   NativeReleasedBranchDeletionContract.resolve(
                     adapter,
                     store,
                     child,
                     NativeReleasedBranchDeletionContract.proof(observed.request),
                     1305
                   )

          assert gone.branch.native_authority.delete_continuation == continued

          assert {:error, _} =
                   ActionContract.finish(
                     adapter,
                     store,
                     gone,
                     :continue,
                     proof(continued.request),
                     1306
                   )

          gone
      end

    assert :ok = ManagedMachine.validate(gone)
    assert NativeBranchDeletionContract.fetch(adapter, store, parent) == parent
    expected = Map.merge(usage, Profile.resources(child.spec.profile), fn _, a, b -> a - b end)
    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    roundtrip(gone)
    gone
  end
end
