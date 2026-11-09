defmodule SmolBox.DurableHost.NativePartialBranchCleanupResolutionStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedPartialBranchCleanup}
  alias SmolBox.DurableHost.{Database, Repo, Store}
  alias SmolBox.Embedded.{Config, NativeGrowth, PartialBranchDisposalCleanupUnneeded, SDKIdentity}
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.NativePartialBranchCleanupResolutionContract, as: Resolution

  setup do
    partition =
      "cleanup-resolution-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ["deleted", "resolved_absent"] do
    test "#{mode} #{provenance} keeps the unneeded acknowledgement distinct in encrypted paired records",
         %{store: store} do
      Resolution.complete(Store, store, unquote(mode), unquote(provenance))
    end
  end

  test "crossed requests swapped proof types and stale observations preserve both encrypted records and accounting",
       %{store: store} do
    Resolution.reject_crossed(Store, store)
  end

  for provenance <- ["deleted", "resolved_absent"] do
    test "#{provenance} deterministic transaction rollback retains the accepted request and all capacity",
         %{store: store} do
      {parent, child, metadata, usage} = Resolution.prepare(Store, store, :initial_release)
      assert {:ok, pending} = Resolution.accept(Store, store, parent, child, child.version, 1401)
      source = Resolution.fetch(Store, store, parent)
      response = Resolution.result(pending, metadata, unquote(provenance))

      assert {:error, :modeled_rollback} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Resolution.resolve(Store, store, source, pending, response, 1402)

                 {:error, :modeled_rollback}
               end)

      assert Resolution.fetch(Store, store, parent) == source and
               Resolution.fetch(Store, store, child) == pending

      assert {:ok, ^usage} = Store.usage(store, source.worker_id)
      assert {:ok, _} = Resolution.resolve(Store, store, source, pending, response, 1403)
    end
  end

  test "a stale child result cannot consume the saved cleanup after an ordinary claim", %{
    store: store
  } do
    {parent, child, metadata, usage} = Resolution.prepare(Store, store, :held)
    assert {:ok, pending} = Resolution.accept(Store, store, parent, child, child.version, 1401)
    source = Resolution.fetch(Store, store, parent)
    response = Resolution.result(pending, metadata, "deleted")

    assert {:ok, current} =
             Store.machine(store, :claim, [ManagedMachine.key(child), "owner", 1402, 10_000])

    assert current.branch.native_authority.partial_disposal.cleanup ==
             pending.branch.native_authority.partial_disposal.cleanup

    assert {:error, _} = Resolution.resolve(Store, store, source, current, response, 1403)

    assert Resolution.fetch(Store, store, parent) == source and
             Resolution.fetch(Store, store, child) == current

    assert {:ok, ^usage} = Store.usage(store, source.worker_id)

    assert {:ok, _} =
             Resolution.resolve(
               Store,
               store,
               source,
               current,
               %{response | version: current.version},
               1404
             )
  end

  for provenance <- ["deleted", "resolved_absent"] do
    test "#{provenance} retirement and backing closure keep the immutable acknowledgement and retire all accounting",
         %{store: store} do
      {parent, child, _, _, _} = Resolution.complete(Store, store, :held, unquote(provenance))
      Resolution.close_storage(Store, store, parent, child)
    end
  end

  test "the new reader marker alone does not advertise native branch admission", %{store: store} do
    assert {:ok, %{native_partial_branch_cleanup_resolutions: 1} = caps} =
             Store.capabilities(store)

    assert caps.native_branches == 1
  end

  for provenance <- ["deleted", "resolved_absent"] do
    test "#{provenance} bounded backend resolution and fresh observation commit through encrypted paired guards",
         %{store: store} do
      {parent, child, metadata, usage} = Resolution.prepare(Store, store, :initial_release)
      assert {:ok, pending} = Resolution.accept(Store, store, parent, child, child.version, 1401)
      source = Resolution.fetch(Store, store, parent)
      context = backend_context(source, metadata)
      expected = Resolution.result(pending, metadata, unquote(provenance))

      budget = %Budget{
        timeout_ms: 5000,
        max_request_bytes: 64 * 1024,
        max_response_bytes: 192 * 1024
      }

      call = fn context, request, budget ->
        send(self(), {:bounded_pipeline, request, budget})

        response =
          case request["operation"] do
            "cleanup_partial_branch_disposal" ->
              %{"result" => "error", "code" => "ownership", "dispatch" => "not_dispatched"}

            "resolve_partial_branch_cleanup" ->
              assert request["request"] == expected.proof.request

              %{
                "result" => "partial_branch_cleanup_unneeded",
                "proof" => PartialBranchDisposalCleanupUnneeded.to_wire(expected.proof)
              }

            "inspect" ->
              %{
                "result" => "observed",
                "observation" => %{
                  "resources" => EmbeddedContext.resources(context),
                  "state" => "running",
                  "pid_identity" => metadata.source.backend_identity.pid_identity
                }
              }
          end

        {:ok, response, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
      end

      assert {:ok, result} =
               EmbeddedPartialBranchCleanup.coordinate(
                 context,
                 :cleanup_partial_branch_disposal,
                 source,
                 pending,
                 budget,
                 call
               )

      assert result == expected
      assert {:ok, ^usage} = Store.usage(store, source.worker_id)
      assert {:ok, completed} = Resolution.resolve(Store, store, source, pending, result, 1402)
      saved = completed.branch.native_authority.partial_disposal
      assert saved.cleanup.unneeded == result.proof and saved.cleanup.proof == nil
      assert saved.proof.completion == unquote(provenance)

      for operation <- ~w(cleanup_partial_branch_disposal resolve_partial_branch_cleanup inspect) do
        assert_receive {:bounded_pipeline, %{"operation" => ^operation}, stage}
        assert stage.max_request_bytes <= 32 * 1024 and stage.max_response_bytes <= 96 * 1024
      end
    end
  end

  # Future descriptor + in-process wire peer only; no package/native admission.
  defp backend_context(source, metadata) do
    revision = "9f446ae00219148ca4a703914f44a8e2fab11655"
    sdk = SDKIdentity.implemented("1.22.0", revision)

    sdk =
      sdk
      |> put_in(~w(feature_versions branches), 1)
      |> put_in(~w(feature_versions partial_cleanup_resolution), 1)

    config =
      struct(Config,
        platform: :macos,
        sdk_identity: sdk,
        package_identity: %{"engine_version" => "0.2.0", "smolvm_revision" => revision}
      )

    assert {:error, _} = Config.validate(config)
    {:ok, identity} = NativeGrowth.current_identity(source)
    {:ok, history} = NativeGrowth.transitions(source)

    %EmbeddedContext{
      config: config,
      pinned: true,
      quiesced: true,
      epoch: get_in(metadata.publication, ~w(change child_origin intent epoch)),
      server: self(),
      identity: identity,
      history: history,
      spec: source.spec,
      assignment: source.backend_assignment,
      profile: source.spec.profile,
      name: source.machine_name
    }
  end
end
