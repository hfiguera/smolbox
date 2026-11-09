defmodule SmolBox.DurableHost.NativeCollectedBranchPublicationStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.{Budget, EmbeddedCollectedBranchPublication, EmbeddedContext}
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Embedded.{BranchPublication, Config, NativeGrowth}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.NativeCollectedBranchPublicationContract, as: Contract
  alias SmolBox.Store.NativeUnbootedBranchDisposalContract, as: Disposal

  setup do
    partition =
      "collected-publication-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for hold <- [true, false] do
    test "held=#{hold} encrypted paired publication preserves all reservations and then resolves ready",
         %{store: store} do
      {parent, child, _, completion, usage} = Contract.complete(Store, store, unquote(hold))
      assert {:ok, ready} = Disposal.resolve(Store, store, parent, child, completion, 1110)
      assert ready.branch.state == if(unquote(hold), do: :held, else: :ready)

      assert Contract.fetch(Store, store, parent).native_branch_history ==
               parent.native_branch_history

      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    end

    test "held=#{hold} positive unbooted disposal consumes the already recorded publication", %{
      store: store
    } do
      {parent, child, _, completion, _} = Contract.complete(Store, store, unquote(hold))
      assert {:ok, pending} = Disposal.accept(Store, store, parent, child, child.version, 1110)
      parent = Contract.fetch(Store, store, parent)

      assert {:ok, disposed} =
               Disposal.resolve(
                 Store,
                 store,
                 parent,
                 pending,
                 Disposal.result(pending, completion),
                 1111
               )

      assert disposed.branch.state == :disposed and disposed.reservation == nil

      assert Contract.fetch(Store, store, parent).native_branch_history ==
               parent.native_branch_history
    end
  end

  test "crossed proof observation version and platform reject both encrypted writes", %{
    store: store
  } do
    Contract.reject_crossed(Store, store)
  end

  test "modeled rollback leaves the saved control and both reservations intact", %{store: store} do
    {parent, child, completion, usage} = Contract.prepare(Store, store, false)
    assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Store, store, parent)
    result = Contract.result(pending, completion)

    assert {:error, :modeled_rollback} =
             Repo.transact(fn ->
               assert {:ok, _} = Contract.finish(Store, store, parent, pending, result, 1104)
               {:error, :modeled_rollback}
             end)

    assert Contract.fetch(Store, store, parent) == parent and
             Contract.fetch(Store, store, pending) == pending

    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
    assert {:ok, _} = Contract.finish(Store, store, parent, pending, result, 1105)
  end

  test "ordinary claim retains the frozen request but requires the fresh child version", %{
    store: store
  } do
    {parent, child, completion, usage} = Contract.prepare(Store, store, false)
    assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Store, store, parent)
    result = Contract.result(pending, completion)

    assert {:ok, claimed} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1104, 10_000])

    assert {:error, _} = Contract.finish(Store, store, parent, claimed, result, 1105)
    assert Contract.fetch(Store, store, parent) == parent
    assert {:ok, ^usage} = Store.usage(store, parent.worker_id)

    assert {:ok, _} =
             Contract.finish(
               Store,
               store,
               parent,
               claimed,
               %{result | version: claimed.version},
               1106
             )

    assert {:ok, %{native_collected_branch_publications: 1} = caps} = Store.capabilities(store)
    assert caps.native_branches == 1
  end

  test "publication before partial collection and disposal appends the history only once", %{
    store: store
  } do
    Contract.complete_partial(Store, store)
  end

  test "publication after partial collection binds its exact material digest", %{store: store} do
    Contract.publish_after_collection(Store, store)
  end

  for hold <- [true, false] do
    test "held=#{hold} translated native proof and fresh source observation commit together in encrypted records",
         %{store: store} do
      {parent, child, completion, usage} = Contract.prepare(Store, store, unquote(hold))
      assert {:ok, pending} = Contract.accept(Store, store, parent, child, child.version, 1103)
      parent = Contract.fetch(Store, store, parent)
      response = Contract.result(pending, completion)
      {:ok, identity} = NativeGrowth.current_identity(parent)
      {:ok, history} = NativeGrowth.transitions(parent)

      context = %EmbeddedContext{
        config: struct(Config, platform: :macos),
        server: self(),
        pinned: true,
        quiesced: true,
        epoch: get_in(response.proof.change, ~w(child_origin intent epoch)),
        spec: parent.spec,
        profile: parent.spec.profile,
        name: parent.machine_name,
        assignment: parent.backend_assignment,
        identity: identity,
        history: history
      }

      budget = %Budget{
        timeout_ms: 1000,
        max_request_bytes: 24 * 1024,
        max_response_bytes: 84 * 1024
      }

      callback = fn
        _, %{"operation" => "publish_collected_branch_material"}, _ ->
          {:ok,
           %{
             "result" => "collected_branch_material_published",
             "publication" => BranchPublication.to_wire(response.proof)
           }, empty(), nil}

        ctx, %{"operation" => "inspect", "receipt" => receipt}, _ ->
          assert receipt == response.proof.receipt and ctx.identity.transition == response.proof
          {:ok, observation(response.source), empty(), nil}
      end

      assert {:ok, result} =
               EmbeddedCollectedBranchPublication.coordinate(
                 context,
                 parent,
                 pending,
                 budget,
                 callback
               )

      assert result == response

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} = Contract.finish(Store, store, parent, pending, result, 1104)
                 {:error, :modeled_rollback}
               end)

      assert Contract.fetch(Store, store, parent) == parent and
               Contract.fetch(Store, store, pending) == pending

      assert {:ok, ^usage} = Store.usage(store, parent.worker_id)
      assert {:ok, published} = Contract.finish(Store, store, parent, pending, result, 1105)
      assert published.state == :unknown and published.reservation == child.reservation

      assert Contract.fetch(Store, store, parent).native_branch_history == %{
               child.id => result.proof
             }
    end
  end

  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp observation(machine),
    do: %{
      "result" => "observed",
      "observation" => %{
        "state" => Atom.to_string(machine.state),
        "pid_identity" => machine.backend_identity.pid_identity,
        "resources" => %{
          "cpus" => machine.cpus,
          "memory_mib" => machine.memory_mb,
          "storage_gib" => machine.storage_gb,
          "overlay_gib" => machine.overlay_gb
        },
        "configuration" => %{
          "network" => %{"enabled" => false, "hosts" => [], "cidrs" => []},
          "ports" => [],
          "backend" => nil
        }
      }
    }
end
