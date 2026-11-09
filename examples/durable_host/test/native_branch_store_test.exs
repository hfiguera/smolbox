defmodule SmolBox.DurableHost.NativeBranchStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    NativeBranchBackingContract,
    NativeBranchCollectionContract,
    NativeBranchContract,
    NativeBranchDeletionActionContract,
    NativeBranchDeletionContract,
    NativeBranchReleaseContract,
    NativeBranchRetirementContract,
    NativeBranchSiblingContract,
    NativePreparedBranchRetirementContract,
    NativeReleasedBranchCleanupContract,
    NativeReleasedBranchContinuationContract,
    NativeReleasedBranchDeletionContract,
    NativeUnbootedBranchBackingContract,
    NativeUnbootedBranchDisposalContract,
    NativeUnbootedBranchRetirementContract
  }

  setup do
    partition =
      "native-branch-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for first <- [:held, :ready, :released],
      second <- [:held, :ready, :released],
      reverse <- [false, true] do
    test "#{first}/#{second} encrypted siblings retire independently in reverse=#{reverse} order",
         %{
           store: store
         } do
      NativeBranchSiblingContract.complete(
        Store,
        store,
        unquote(first),
        unquote(second),
        unquote(reverse)
      )
    end
  end

  for mode <- [:held, :ready, :released] do
    test "#{mode} encrypted collection preserves uncertainty and all resource charges", %{
      store: store
    } do
      NativeBranchCollectionContract.complete(Store, store, unquote(mode))
    end

    test "#{mode} encrypted continuation preserves independent collection history", %{
      store: store
    } do
      NativeBranchCollectionContract.continue(Store, store, unquote(mode))
    end

    for route <- [:continue, :cleanup, :resolve] do
      test "#{mode} #{route} retains an encrypted pending collection", %{store: store} do
        NativeBranchCollectionContract.interleaved(Store, store, unquote(mode), unquote(route))
      end
    end

    test "#{mode} collection intent and proof roll back with encrypted projections", %{
      store: store
    } do
      {parent, child, usage} = NativeBranchDeletionContract.prepare(Store, store, unquote(mode))

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchCollectionContract.accept(Store, store, child, 1303)

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, pending} = NativeBranchCollectionContract.accept(Store, store, child, 1303)

      proof =
        NativeBranchCollectionContract.proof(
          pending.branch.native_authority.delete_collection.request
        )

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchCollectionContract.finish(
                            Store,
                            store,
                            pending,
                            proof,
                            1304
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, pending) == pending
      assert NativeBranchDeletionContract.fetch(Store, store, parent) == parent
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end
  end

  for mode <- [:ready, :released] do
    test "#{mode} released cleanup retains exact accepted grant and backing", %{store: store} do
      NativeReleasedBranchCleanupContract.complete(Store, store, unquote(mode))
    end

    for route <- [:continue, :cleanup, :resolve] do
      test "#{mode} #{route} retains all encrypted cleanup grants and original accounting",
           %{store: store} do
        NativeReleasedBranchCleanupContract.interleaved(
          Store,
          store,
          unquote(mode),
          unquote(route)
        )
      end
    end

    test "#{mode} released cleanup request and acknowledgement roll back all encrypted projections",
         %{store: store} do
      {parent, child, usage} = NativeBranchDeletionContract.prepare(Store, store, unquote(mode))

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.accept(
                            Store,
                            store,
                            child,
                            :cleanup,
                            1303
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

      assert {:ok, pending} =
               NativeBranchDeletionActionContract.accept(
                 Store,
                 store,
                 child,
                 :cleanup,
                 1303
               )

      proof =
        NativeReleasedBranchCleanupContract.proof(
          pending.branch.native_authority.delete_cleanup.request
        )

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.finish(
                            Store,
                            store,
                            pending,
                            :cleanup,
                            proof,
                            1304
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, pending) == pending
      assert NativeBranchDeletionContract.fetch(Store, store, parent) == parent
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end

    test "#{mode} released continuation retains exact accepted grant and backing", %{store: store} do
      NativeReleasedBranchContinuationContract.complete(Store, store, unquote(mode))
    end

    for route <- [:continue, :resolve] do
      test "#{mode} #{route} retains the other encrypted pending grant and original accounting",
           %{store: store} do
        NativeReleasedBranchContinuationContract.interleaved(
          Store,
          store,
          unquote(mode),
          unquote(route)
        )
      end
    end

    test "#{mode} released continuation request and acknowledgement roll back all encrypted projections",
         %{store: store} do
      {parent, child, usage} = NativeBranchDeletionContract.prepare(Store, store, unquote(mode))

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.accept(
                            Store,
                            store,
                            child,
                            :continue,
                            1303
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

      assert {:ok, pending} =
               NativeBranchDeletionActionContract.accept(
                 Store,
                 store,
                 child,
                 :continue,
                 1303
               )

      proof =
        NativeReleasedBranchContinuationContract.proof(
          pending.branch.native_authority.delete_continuation.request
        )

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.finish(
                            Store,
                            store,
                            pending,
                            :continue,
                            proof,
                            1304
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, pending) == pending
      assert NativeBranchDeletionContract.fetch(Store, store, parent) == parent
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end

    test "#{mode} released delete resolution persists distinct proof and releases only the child slot",
         %{store: store} do
      NativeReleasedBranchDeletionContract.complete(Store, store, unquote(mode))
    end

    test "#{mode} released delete request and proof roll back with all encrypted projections", %{
      store: store
    } do
      {parent, child, usage} =
        NativeReleasedBranchDeletionContract.prepare(Store, store, unquote(mode))

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeReleasedBranchDeletionContract.accept(Store, store, child, 1303)

                 {:error, :injected}
               end)

      assert NativeReleasedBranchDeletionContract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

      assert {:ok, pending} =
               NativeReleasedBranchDeletionContract.accept(Store, store, child, 1303)

      proof =
        NativeReleasedBranchDeletionContract.proof(
          pending.branch.native_authority.deletion.request
        )

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeReleasedBranchDeletionContract.resolve(
                            Store,
                            store,
                            pending,
                            proof,
                            1304
                          )

                 {:error, :injected}
               end)

      assert NativeReleasedBranchDeletionContract.fetch(Store, store, pending) == pending
      assert NativeReleasedBranchDeletionContract.fetch(Store, store, parent) == parent
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end

    test "#{mode} uncertain deletion rejects untyped absence and preserves both encrypted records and every projection",
         %{store: store} do
      NativeBranchDeletionContract.denied_released(Store, store, unquote(mode))
    end
  end

  for hold <- [true, false], provenance <- ["deleted", "resolved_absent"] do
    test "unbooted held=#{hold} provenance=#{provenance} closes only acknowledged original backing",
         %{store: store} do
      NativeUnbootedBranchBackingContract.completed(
        Store,
        store,
        unquote(hold),
        unquote(provenance)
      )
    end
  end

  test "unbooted backing acceptance and acknowledgement roll back both encrypted rows and projections",
       %{store: store} do
    alias SmolBox.Store.NativeUnbootedBranchBackingContract, as: Backing
    {parent, child, usage} = Backing.prepare(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = Backing.accept(Store, store, parent, child, 1312)
               {:error, :injected}
             end)

    assert Backing.fetch(Store, store, parent) == parent
    assert Backing.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, pending} = Backing.accept(Store, store, parent, child, 1312)
    parent = Backing.fetch(Store, store, parent)
    proof = Backing.proof(pending.branch.native_authority.backing.request)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Backing.complete_proof(Store, store, parent, pending, proof, 1313)

               {:error, :injected}
             end)

    assert Backing.fetch(Store, store, parent) == parent
    assert Backing.fetch(Store, store, pending) == pending
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Backing.complete_proof(Store, store, parent, pending, proof, 1314)
    assert {:ok, %{disk_gb: 0}} = Store.usage(store, parent.worker_id)
  end

  for hold <- [true, false], provenance <- ["deleted", "resolved_absent"] do
    test "unbooted held=#{hold} provenance=#{provenance} retires dependency while retaining all extra backing",
         %{store: store} do
      NativeUnbootedBranchRetirementContract.complete(
        Store,
        store,
        unquote(hold),
        unquote(provenance)
      )
    end
  end

  test "unbooted retirement rolls back both encrypted records and projections", %{store: store} do
    alias SmolBox.Store.NativeUnbootedBranchRetirementContract, as: Retirement
    {parent, child, proof, usage} = Retirement.prepare(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = Retirement.advance(Store, store, parent, child, proof, 1201)
               {:error, :injected}
             end)

    assert Retirement.fetch(Store, store, parent) == parent
    assert Retirement.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Retirement.advance(Store, store, parent, child, proof, 1202)
  end

  for hold <- [true, false], provenance <- ["deleted", "resolved_absent"] do
    test "unbooted held=#{hold} provenance=#{provenance} commits source publication and only ordinary child capacity",
         %{store: store} do
      NativeUnbootedBranchDisposalContract.complete(
        Store,
        store,
        unquote(hold),
        unquote(provenance)
      )
    end
  end

  test "unbooted disposal request proof source and capacity projections roll back together", %{
    store: store
  } do
    alias SmolBox.Store.NativeUnbootedBranchDisposalContract, as: Disposal
    {parent, child, completion, usage} = Disposal.prepare(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = Disposal.accept(Store, store, parent, child, child.version, 1103)
               {:error, :injected}
             end)

    assert Disposal.fetch(Store, store, parent) == parent
    assert Disposal.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, child} = Disposal.accept(Store, store, parent, child, child.version, 1103)
    parent = Disposal.fetch(Store, store, parent)
    result = Disposal.result(child, completion)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = Disposal.resolve(Store, store, parent, child, result, 1104)
               {:error, :injected}
             end)

    assert Disposal.fetch(Store, store, parent) == parent
    assert Disposal.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Disposal.resolve(Store, store, parent, child, result, 1104)
  end

  for hold <- [true, false] do
    test "held=#{hold} prepared retirement retains nonmaterial history and releases only pre-entry charges",
         %{store: store} do
      NativePreparedBranchRetirementContract.complete(Store, store, unquote(hold))
    end
  end

  test "prepared retirement source child codec and resource projections roll back together", %{
    store: store
  } do
    {parent, child, result, usage} =
      NativePreparedBranchRetirementContract.prepare(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativePreparedBranchRetirementContract.resolve(
                          Store,
                          store,
                          parent,
                          child,
                          result,
                          1103
                        )

               {:error, :injected}
             end)

    assert NativePreparedBranchRetirementContract.fetch(Store, store, parent) == parent
    assert NativePreparedBranchRetirementContract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativePreparedBranchRetirementContract.resolve(
               Store,
               store,
               parent,
               child,
               result,
               1103
             )
  end

  for uncertain <- [false, true] do
    test "native held release uncertain=#{uncertain} pairs source child and retained projections",
         %{store: store} do
      NativeBranchReleaseContract.completed(Store, store, unquote(uncertain))
    end
  end

  for mode <- [:held, :ready, :released] do
    test "#{mode} native retirement atomically retains proof dependency history and backing projections",
         %{store: store} do
      NativeBranchRetirementContract.complete(Store, store, unquote(mode))
    end
  end

  test "native retirement rolls back source child proof and resource projections together", %{
    store: store
  } do
    {parent, child, proof, usage} =
      NativeBranchRetirementContract.prepare(Store, store, :released)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchRetirementContract.advance(
                          Store,
                          store,
                          parent,
                          child,
                          proof,
                          1304
                        )

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^child} = Store.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativeBranchRetirementContract.advance(Store, store, parent, child, proof, 1305)
  end

  test "held release intent and completion each roll back both records and projections", %{
    store: store
  } do
    {parent, child, _, usage} = NativeBranchContract.complete(Store, store, true)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Store.machine(store, :branch_release, [
                          ManagedMachine.key(child),
                          child.version,
                          1200
                        ])

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^child} = Store.machine(store, :fetch, [ManagedMachine.key(child)])

    assert {:ok, pending} =
             Store.machine(store, :branch_release, [
               ManagedMachine.key(child),
               child.version,
               1200
             ])

    assert {:ok, pending} =
             Store.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1200, 10_000])

    assert {:ok, sent} =
             NativeBranchReleaseContract.advance(Store, store, pending, :dispatching, 1201)

    assert {:ok, parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    result = NativeBranchReleaseContract.result(parent, sent)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchReleaseContract.advance(
                          Store,
                          store,
                          sent,
                          {:native_complete, result},
                          1202
                        )

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^sent} = Store.machine(store, :fetch, [ManagedMachine.key(sent)])
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
  end

  for hold <- [true, false] do
    test "native held=#{hold} explicit kept resolution binds historical completion and current observations",
         %{store: store} do
      NativeBranchContract.resolve_completed(Store, store, unquote(hold))
    end

    test "native held=#{hold} completion retains exact source child and backing atomically", %{
      store: store
    } do
      NativeBranchContract.complete(Store, store, unquote(hold))
    end
  end

  test "source publication child completion and projections roll back together", %{store: store} do
    {parent, child, result} = NativeBranchContract.prepare(Store, store, false)

    assert {:ok, sent} =
             NativeBranchContract.advance(
               Store,
               store,
               parent,
               child,
               :accepted,
               :dispatching,
               1101
             )

    assert {:ok, parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, usage} = Store.usage(store, parent.worker_id)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchContract.advance(
                          Store,
                          store,
                          parent,
                          child,
                          :dispatching,
                          {:native_complete, result},
                          1102
                        )

               {:error, :injected}
             end)

    assert {:ok, ^parent} = Store.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^sent} = Store.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativeBranchContract.advance(
               Store,
               store,
               parent,
               child,
               :dispatching,
               {:native_complete, result},
               1102
             )
  end

  for mode <- [:held, :ready, :released] do
    test "#{mode} backing request and acknowledgement preserve original authority and exact charges",
         %{store: store} do
      NativeBranchBackingContract.completed(Store, store, unquote(mode))
    end
  end

  test "backing acceptance and acknowledgement roll back both rows and every projection", %{
    store: store
  } do
    {parent, child, usage} = NativeBranchBackingContract.prepare(Store, store, :held)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchBackingContract.accept(Store, store, parent, child, 1312)

               {:error, :injected}
             end)

    assert NativeBranchBackingContract.fetch(Store, store, parent) == parent
    assert NativeBranchBackingContract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, pending} = NativeBranchBackingContract.accept(Store, store, parent, child, 1312)
    parent = NativeBranchBackingContract.fetch(Store, store, parent)
    proof = NativeBranchBackingContract.proof(pending.branch.native_authority.backing.request)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchBackingContract.complete_proof(
                          Store,
                          store,
                          parent,
                          pending,
                          proof,
                          1313
                        )

               {:error, :injected}
             end)

    assert NativeBranchBackingContract.fetch(Store, store, parent) == parent
    assert NativeBranchBackingContract.fetch(Store, store, pending) == pending
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
  end

  test "held delete acceptance and proof resolution release only the child slot", %{store: store} do
    NativeBranchDeletionContract.complete(Store, store)
  end

  test "held delete acceptance and resolution roll back proof and resource projections", %{
    store: store
  } do
    {parent, child, usage} = NativeBranchDeletionContract.prepare(Store, store)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} = NativeBranchDeletionContract.accept(Store, store, child, 1303)
               {:error, :injected}
             end)

    assert NativeBranchDeletionContract.fetch(Store, store, child) == child
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, pending} = NativeBranchDeletionContract.accept(Store, store, child, 1303)
    proof = NativeBranchDeletionContract.proof(pending.branch.native_authority.deletion.request)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        NativeBranchDeletionContract.resolve(Store, store, pending, proof, 1304)

               {:error, :injected}
             end)

    assert NativeBranchDeletionContract.fetch(Store, store, pending) == pending
    assert NativeBranchDeletionContract.fetch(Store, store, parent) == parent
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
  end

  for action <- [:continue, :cleanup] do
    test "held delete #{action} acceptance and acknowledgement retain backing", %{store: store} do
      NativeBranchDeletionActionContract.complete(Store, store, unquote(action))
    end

    test "held delete #{action} rolls back action history and resource projections", %{
      store: store
    } do
      action = unquote(action)
      {parent, child, usage} = NativeBranchDeletionContract.prepare(Store, store)

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.accept(
                            Store,
                            store,
                            child,
                            action,
                            1303
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, child) == child
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

      assert {:ok, pending} =
               NativeBranchDeletionActionContract.accept(Store, store, child, action, 1303)

      proof =
        NativeBranchDeletionActionContract.proof(
          NativeBranchDeletionActionContract.saved(pending, action).request
        )

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          NativeBranchDeletionActionContract.finish(
                            Store,
                            store,
                            pending,
                            action,
                            proof,
                            1304
                          )

                 {:error, :injected}
               end)

      assert NativeBranchDeletionContract.fetch(Store, store, pending) == pending
      assert NativeBranchDeletionContract.fetch(Store, store, parent) == parent
      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end
  end
end
