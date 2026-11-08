defmodule SmolBox.EmbeddedBranchDeletionActionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Error}

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedBranchDeletionAction,
    EmbeddedContext,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{Config, NativeGrowth}
  alias SmolBox.Store.{Memory, NativeBranchDeletionActionContract, NativeBranchDeletionContract}
  @budget %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp other(:continue), do: :cleanup
  defp other(:cleanup), do: :continue
  defp operation(:continue), do: :continue_branch_deletion
  defp operation(:cleanup), do: :cleanup_branch_deletion
  defp result(:continue), do: "held_branch_deletion_continued"
  defp result(:cleanup), do: "held_branch_deletion_cleaned"

  defp wire(proof),
    do: Map.new(Map.from_struct(proof), fn {key, value} -> {Atom.to_string(key), value} end)

  defp fixture(action) do
    store = start_supervised!(Memory)
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)

    assert {:ok, child} =
             NativeBranchDeletionActionContract.accept(Memory, store, child, action, 1303)

    {:ok, identity} = NativeGrowth.current_identity(child)

    proof =
      NativeBranchDeletionActionContract.proof(
        NativeBranchDeletionActionContract.saved(child, action).request
      )

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

  defp peer(proof, action, observer, transform \\ &Function.identity/1),
    do: fn context, operation, budget ->
      send(observer, {:called, context, operation, budget})
      transform.({:ok, %{"result" => result(action), "proof" => wire(proof)}, @empty, nil})
    end

  for action <- [:continue, :cleanup] do
    test "#{action} exact accepted request retains original pin finite budget and public admission gate" do
      action = unquote(action)
      {child, proof, context} = fixture(action)

      assert {:ok, ^proof} =
               EmbeddedBranchDeletionAction.coordinate(
                 context,
                 child,
                 action,
                 @budget,
                 peer(proof, action, self())
               )

      assert_receive {:called, pinned, %{"operation" => name, "request" => request}, budget}
      assert name == "#{action}_held_branch_deletion"
      assert pinned.server == context.server and pinned.epoch == context.epoch and pinned.quiesced
      assert request == NativeBranchDeletionActionContract.saved(child, action).request
      assert budget.timeout_ms <= 1000 and budget.max_response_bytes <= 8192
      refute Embedded.supports_operation?(context, operation(action))

      assert {:error, %Error{evidence: :not_dispatched}} =
               EmbeddedBranchDeletionAction.run(context, child, action, @budget)
    end

    test "#{action} rejects missing authority foreign scope and platform before helper entry" do
      action = unquote(action)
      {child, proof, context} = fixture(action)

      for changed <- [
            %{context | quiesced: false},
            %{context | pinned: false},
            %{context | epoch: nil},
            %{context | branch_deletion: nil},
            %{context | name: "another-child"},
            %{context | config: %{context.config | platform: :linux}}
          ] do
        assert {:error, %Error{evidence: :not_dispatched}} =
                 EmbeddedBranchDeletionAction.coordinate(
                   changed,
                   child,
                   action,
                   @budget,
                   peer(proof, action, self())
                 )

        refute_receive {:called, _, _, _}
      end

      other = other(action)

      assert {:error, %Error{evidence: :not_dispatched}} =
               EmbeddedBranchDeletionAction.coordinate(
                 context,
                 child,
                 other,
                 @budget,
                 peer(proof, action, self())
               )

      refute_receive {:called, _, _, _}
    end

    test "#{action} bare crossed output overlay and late responses cannot acknowledge completion" do
      action = unquote(action)
      {child, proof, context} = fixture(action)

      for response <- [
            {:ok, :absent},
            {:ok, %{"result" => result(action), "proof" => nil}, @empty, nil},
            {:ok, %{"result" => "held_branch_deletion_resolved", "proof" => wire(proof)}, @empty,
             nil},
            {:ok, %{"result" => result(action), "proof" => wire(proof)},
             %{@empty | stdout: "extra"}, nil},
            {:ok, %{"result" => result(action), "proof" => wire(proof)}, @empty,
             %Error{category: :unknown, operation: :reconcile}}
          ] do
        assert {:error, %Error{evidence: :dispatch_uncertain}} =
                 EmbeddedBranchDeletionAction.coordinate(
                   context,
                   child,
                   action,
                   @budget,
                   peer(proof, action, self(), fn _ -> response end)
                 )
      end

      late =
        peer(proof, action, self(), fn response ->
          Process.sleep(150)
          response
        end)

      assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
               EmbeddedBranchDeletionAction.coordinate(
                 context,
                 child,
                 action,
                 @budget,
                 late,
                 System.monotonic_time(:millisecond) + 100
               )
    end

    test "HTTP #{action} rejects before native transport dispatch" do
      ref = %Reference{
        adapter: HTTP,
        kind: :http,
        id: "http-worker",
        context: nil,
        budget: @budget
      }

      assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
               Backend.invoke(ref, operation(unquote(action)), [nil])
    end
  end
end
