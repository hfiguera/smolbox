defmodule SmolBox.EmbeddedBranchRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, Embedded, EmbeddedBranchRetirement, EmbeddedContext}
  alias SmolBox.Embedded.{BranchChildAbsence, Config, NativeGrowth}
  alias SmolBox.{Error, ManagedMachine}
  alias SmolBox.Store.{Memory, NativeBranchRetirementContract}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @budget %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}

  defp fixture do
    store = start_supervised!(Memory)
    {parent, child, proof, usage} = NativeBranchRetirementContract.prepare(Memory, store, :held)
    assert {:ok, identity} = NativeGrowth.current_identity(child)

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

  defp peer(proof, observer, transform \\ fn result -> result end),
    do: fn context, request, budget ->
      send(observer, {:called, context, request, budget})

      transform.(
        {:ok, %{"result" => "branch_child_absent", "proof" => BranchChildAbsence.to_wire(proof)},
         @empty, nil}
      )
    end

  test "fenced original child scope receives exact absence proof under one captured owner and budget" do
    {store, parent, child, proof, context, usage} = fixture()

    assert {:ok, ^proof} =
             EmbeddedBranchRetirement.coordinate(
               context,
               child.machine_name,
               @budget,
               peer(proof, self())
             )

    assert_receive {:called, pinned,
                    %{"operation" => "qualify_branch_child_absence", "request" => request},
                    budget}

    assert pinned.server == context.server and pinned.epoch == context.epoch and pinned.quiesced
    assert request == proof.request and request["child"] == context.identity.receipt
    assert budget.timeout_ms <= 1000 and budget.max_response_bytes <= 72 * 1024
    assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    refute Embedded.supports_operation?(context, :branch_absent)

    assert {:error, %Error{evidence: :not_dispatched}} =
             EmbeddedBranchRetirement.run(context, child.machine_name, @budget)
  end

  test "missing owner fencing or changed source scope rejects before any peer request" do
    {_, _, child, proof, context, _} = fixture()

    for changed <- [
          %{context | quiesced: false},
          %{context | pinned: false},
          %{context | epoch: nil},
          %{context | branch_retirement: nil},
          %{context | spec: %{context.spec | id: "another-child"}}
        ] do
      assert {:error, _} =
               EmbeddedBranchRetirement.coordinate(
                 changed,
                 child.machine_name,
                 @budget,
                 peer(proof, self())
               )

      refute_receive {:called, _, _, _}
    end
  end

  test "bare absence proof substitutions streams overlays and late observations cannot retire dependency" do
    {store, parent, child, proof, context, usage} = fixture()

    for response <- [
          {:ok, :absent},
          {:ok, %{"result" => "branch_child_absent", "proof" => nil}, @empty, nil},
          {:ok,
           %{"result" => "branch_child_absent", "proof" => BranchChildAbsence.to_wire(proof)},
           %{@empty | file: "extra"}, nil},
          {:ok,
           %{"result" => "branch_child_absent", "proof" => BranchChildAbsence.to_wire(proof)},
           @empty, %Error{category: :unknown, operation: :branch}}
        ] do
      assert {:error, _} =
               EmbeddedBranchRetirement.coordinate(
                 context,
                 child.machine_name,
                 @budget,
                 peer(proof, self(), fn _ -> response end)
               )
    end

    late =
      peer(proof, self(), fn result ->
        Process.sleep(210)
        result
      end)

    assert {:error, %Error{category: :expired}} =
             EmbeddedBranchRetirement.coordinate(
               context,
               child.machine_name,
               @budget,
               late,
               System.monotonic_time(:millisecond) + 200
             )

    assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end
end
