defmodule SmolBox.EmbeddedReleasedBranchDeletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Error}

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedBranchDeletion,
    EmbeddedContext,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{Config, NativeGrowth, ReleasedBranchDeletionResolution}
  alias SmolBox.Store.{Memory, NativeReleasedBranchDeletionContract}
  @budget %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  defp fixture(mode) do
    store = start_supervised!(Memory)
    {_, child, _} = NativeReleasedBranchDeletionContract.prepare(Memory, store, mode)
    assert {:ok, child} = NativeReleasedBranchDeletionContract.accept(Memory, store, child, 1303)
    {:ok, identity} = NativeGrowth.current_identity(child)

    proof =
      NativeReleasedBranchDeletionContract.proof(child.branch.native_authority.deletion.request)

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: self(),
      epoch: String.duplicate("a", 32),
      pinned: true,
      quiesced: true,
      name: child.machine_name,
      spec: child.spec,
      profile: child.spec.profile,
      assignment: child.backend_assignment,
      identity: identity,
      branch_deletion: child
    }

    {child, proof, context}
  end

  defp peer(proof, observer, transform \\ &Function.identity/1),
    do: fn context, operation, budget ->
      send(observer, {:called, context, operation, budget})

      transform.(
        {:ok,
         %{
           "result" => "released_branch_deletion_resolved",
           "proof" => ReleasedBranchDeletionResolution.to_wire(proof)
         }, @empty, nil}
      )
    end

  for origin <- [:ready, :released] do
    test "#{origin} original accepted child request uses one pin and finite control budget while production remains gated" do
      {child, proof, context} = fixture(unquote(origin))

      assert {:ok, ^proof} =
               EmbeddedBranchDeletion.coordinate(context, child, @budget, peer(proof, self()))

      assert_receive {:called, pinned,
                      %{"operation" => "resolve_released_branch_deletion", "request" => request},
                      budget}

      assert pinned.epoch == context.epoch and pinned.server == context.server and pinned.quiesced
      assert request == child.branch.native_authority.deletion.request
      assert budget.timeout_ms <= 1000 and budget.max_response_bytes <= 8192
      refute Embedded.supports_operation?(context, :resolve_branch_deletion)

      assert {:error, %Error{evidence: :not_dispatched}} =
               EmbeddedBranchDeletion.run(context, child, @budget)
    end

    test "#{origin} scope fencing missing intent output overlays and late evidence cannot resolve deletion" do
      {child, proof, context} = fixture(unquote(origin))

      for changed <- [
            %{context | quiesced: false},
            %{context | pinned: false},
            %{context | epoch: nil},
            %{context | branch_deletion: nil},
            %{context | name: "another-child"}
          ] do
        assert {:error, _} =
                 EmbeddedBranchDeletion.coordinate(changed, child, @budget, peer(proof, self()))

        refute_receive {:called, _, _, _}
      end

      for response <- [
            {:ok, :absent},
            {:ok, %{"result" => "released_branch_deletion_resolved", "proof" => nil}, @empty,
             nil},
            {:ok,
             %{
               "result" => "released_branch_deletion_resolved",
               "proof" => ReleasedBranchDeletionResolution.to_wire(proof)
             }, %{@empty | file: "extra"}, nil},
            {:ok,
             %{
               "result" => "released_branch_deletion_resolved",
               "proof" => ReleasedBranchDeletionResolution.to_wire(proof)
             }, @empty, %Error{category: :unknown, operation: :reconcile}}
          ] do
        assert {:error, _} =
                 EmbeddedBranchDeletion.coordinate(
                   context,
                   child,
                   @budget,
                   peer(proof, self(), fn _ -> response end)
                 )
      end

      late =
        peer(proof, self(), fn result ->
          Process.sleep(150)
          result
        end)

      assert {:error, %Error{category: :expired}} =
               EmbeddedBranchDeletion.coordinate(
                 context,
                 child,
                 @budget,
                 late,
                 System.monotonic_time(:millisecond) + 100
               )
    end

    test "#{origin} HTTP rejects native deletion resolution before transport dispatch" do
      ref = %Reference{
        adapter: HTTP,
        kind: :http,
        id: "http-worker",
        context: nil,
        budget: @budget
      }

      assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
               Backend.resolve_branch_deletion(ref, nil)
    end
  end
end
