defmodule SmolBox.EmbeddedBranchBackingTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Error, ManagedMachine}

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedBranchBacking,
    EmbeddedContext,
    HTTP,
    Reference
  }

  alias SmolBox.Embedded.{BranchBackingRelease, Config, NativeGrowth}
  alias SmolBox.Store.{Memory, NativeBranchBackingContract}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @budget %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}

  defp fixture do
    store = start_supervised!(Memory)
    {parent, child, usage} = NativeBranchBackingContract.prepare(Memory, store, :held)
    assert {:ok, child} = NativeBranchBackingContract.accept(Memory, store, parent, child, 1312)
    parent = NativeBranchBackingContract.fetch(Memory, store, parent)
    assert {:ok, identity} = NativeGrowth.current_identity(child)
    proof = NativeBranchBackingContract.proof(child.branch.native_authority.backing.request)

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: self(),
      pinned: true,
      quiesced: true,
      epoch: String.duplicate("a", 32),
      name: child.machine_name,
      spec: child.spec,
      assignment: child.backend_assignment,
      profile: child.spec.profile,
      identity: identity,
      branch_retirement: child
    }

    {store, parent, child, proof, context, usage}
  end

  defp peer(proof, observer, transform \\ &Function.identity/1),
    do: fn context, request, budget ->
      send(observer, {:called, context, request, budget})

      transform.(
        {:ok,
         %{"result" => "branch_backing_released", "proof" => BranchBackingRelease.to_wire(proof)},
         @empty, nil}
      )
    end

  test "accepted request and original pair stay bound to one captured owner and budget" do
    {store, parent, child, proof, context, usage} = fixture()

    assert {:ok, ^proof} =
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               @budget,
               peer(proof, self())
             )

    assert_receive {:called, pinned,
                    %{"operation" => "release_branch_backing", "request" => request}, budget}

    assert request == child.branch.native_authority.backing.request
    assert pinned.server == context.server and pinned.epoch == context.epoch and pinned.quiesced
    assert budget.timeout_ms <= 1000 and budget.max_response_bytes <= 72 * 1024
    assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    refute Embedded.supports_operation?(context, :release_branch_backing)

    assert {:error, %Error{evidence: :not_dispatched}} =
             EmbeddedBranchBacking.run(context, parent, child, true, @budget)
  end

  test "unfenced changed pair scope or missing accepted intent rejects before native IO" do
    {_, parent, child, proof, context, _} = fixture()

    for {ctx, p, removed} <- [
          {%{context | quiesced: false}, parent, true},
          {%{context | pinned: false}, parent, true},
          {%{context | epoch: nil}, parent, true},
          {%{context | branch_retirement: nil}, parent, true},
          {%{context | name: "other-name"}, parent, true},
          {context, %{parent | native_branch_history: %{}}, true},
          {context, %{parent | state: :stopped}, true},
          {context, parent, false}
        ] do
      assert {:error, _} =
               EmbeddedBranchBacking.coordinate(
                 ctx,
                 p,
                 child,
                 removed,
                 @budget,
                 peer(proof, self())
               )

      refute_receive {:called, _, _, _}
    end
  end

  test "bare wrong-charge output overlay and late replies retain the pending public charge" do
    {store, parent, child, proof, context, usage} = fixture()

    for response <- [
          {:ok, :absent},
          {:ok, %{"result" => "branch_backing_released", "proof" => nil}, @empty, nil},
          {:ok,
           %{
             "result" => "branch_backing_released",
             "proof" =>
               BranchBackingRelease.to_wire(%{proof | native_bytes: proof.native_bytes + 1})
           }, @empty, nil},
          {:ok,
           %{
             "result" => "branch_backing_released",
             "proof" => BranchBackingRelease.to_wire(proof)
           }, %{@empty | file: "extra"}, nil},
          {:ok,
           %{
             "result" => "branch_backing_released",
             "proof" => BranchBackingRelease.to_wire(proof)
           }, @empty, %Error{category: :unknown, operation: :branch}}
        ] do
      assert {:error, _} =
               EmbeddedBranchBacking.coordinate(
                 context,
                 parent,
                 child,
                 true,
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
             EmbeddedBranchBacking.coordinate(
               context,
               parent,
               child,
               true,
               @budget,
               late,
               System.monotonic_time(:millisecond) + 100
             )

    assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "HTTP reference rejects native accounting entry without invoking its transport" do
    reference = %Reference{
      adapter: HTTP,
      kind: :http,
      id: "http-worker",
      context: nil,
      budget: @budget
    }

    assert {:error, %Error{category: :unsupported_capability, evidence: :not_dispatched}} =
             Backend.release_branch_backing(reference, nil, nil, true)
  end
end
