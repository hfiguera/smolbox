defmodule SmolBox.Runtime.BranchObservationTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, Reference}
  alias SmolBox.Error
  alias SmolBox.ManagedMachine
  alias SmolBox.Runtime.{BranchObservation, Target}
  alias SmolBox.Store.{BranchContract, Memory}

  # Semantic owner/transport model only. No native helper or fault campaign.
  defmodule ScopedAdapter do
    @behaviour SmolBox.Backend
    @impl true
    def supports_operation?(_, operation),
      do: operation in [:inspect_machine, :branch_absent, :branch_inspect_child]

    @impl true
    def pin(%{pinned: true} = context, _budget), do: {:ok, context}

    def pin(context, _budget) do
      owner = Agent.get(context.state, & &1.owner)
      send(context.observer, {:pin, owner})
      {:ok, %{context | pinned: true, owner: owner}}
    end

    @impl true
    def assign(context, record),
      do: {:ok, %{context | record: record}}

    @impl true
    def invoke(context, operation, arguments, budget) do
      record = context.record

      send(
        context.observer,
        {:called, context.owner, ManagedMachine.key(record), operation, arguments, budget}
      )

      Agent.get_and_update(context.state, fn state ->
        result =
          if context.owner != nil and context.owner == state.live,
            do: Map.fetch!(state.responses, {operation, record.machine_name}),
            else:
              {:error,
               %Error{category: :unknown, operation: :branch, evidence: :dispatch_uncertain}}

        next =
          if state.replace,
            do: %{state | replace: false, owner: :replacement, live: :replacement},
            else: state

        {result, next}
      end)
    end
  end

  setup do
    store = start_supervised!(Memory)
    original = BranchContract.running(Memory, store)
    {:ok, child} = BranchContract.accept(Memory, store, original)
    {:ok, parent} = Memory.machine(store, :fetch, [ManagedMachine.key(original)])
    observed = %{parent.created_machine | name: child.machine_name}

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             owner: :original,
             live: :original,
             replace: false,
             responses: %{
               {:inspect_machine, parent.machine_name} => {:ok, parent.created_machine},
               {:branch_absent, parent.machine_name} => {:ok, :absent},
               {:branch_absent, child.machine_name} => {:ok, :absent},
               {:branch_inspect_child, child.machine_name} => {:ok, observed}
             }
           }
         end}
      )

    reference = %Reference{
      adapter: ScopedAdapter,
      kind: :embedded,
      id: "worker",
      context: %{observer: self(), state: state, owner: nil, pinned: false, record: nil},
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 4096, max_response_bytes: 8192}
    }

    %{
      worker: %Target{kind: :embedded, id: "worker", connection: reference},
      parent: parent,
      child: child,
      observed: observed,
      state: state
    }
  end

  test "keep resolution assigns source and child authority under one owner", f do
    assert {:ok, [source, child]} =
             BranchObservation.resolution(f.worker, f.parent, f.child, :keep)

    assert source == f.parent.created_machine and child == f.observed
    assert_received {:pin, :original}
    refute_received {:pin, _}
    parent_key = ManagedMachine.key(f.parent)
    child_key = ManagedMachine.key(f.child)
    assert_received {:called, :original, ^parent_key, :inspect_machine, [name], budget}
    assert name == f.parent.machine_name
    assert budget == f.worker.connection.budget

    assert_received {:called, :original, ^child_key, :branch_inspect_child, [record, held],
                     ^budget}

    assert record == f.child and held == f.child.branch.spec.hold
  end

  test "only deleted resolution permits source absence and still checks the assigned child", f do
    missing = {:error, %Error{category: :not_found, operation: :inspect_machine}}
    response(f, :inspect_machine, f.parent, missing)

    assert {:ok, [:absent, :absent]} =
             BranchObservation.resolution(f.worker, f.parent, f.child, :deleted)

    child_key = ManagedMachine.key(f.child)
    assert_received {:called, :original, ^child_key, :branch_absent, [name], _}
    assert name == f.child.machine_name
    assert ^missing = BranchObservation.resolution(f.worker, f.parent, f.child, :keep)
    refute_received {:called, _, _, :branch_inspect_child, _, _}
    refute_received {:called, _, ^child_key, :branch_absent, _, _}
  end

  test "retirement checks only the child's saved authority and storage release checks both", f do
    child_key = ManagedMachine.key(f.child)
    parent_key = ManagedMachine.key(f.parent)
    assert {:ok, []} = BranchObservation.retirement(f.worker, f.child)
    assert_received {:called, :original, ^child_key, :branch_absent, _, _}
    refute_received {:called, _, ^parent_key, _, _, _}
    assert {:ok, []} = BranchObservation.storage_release(f.worker, f.parent, f.child)
    assert_received {:called, :original, ^parent_key, :branch_absent, _, _}
    assert_received {:called, :original, ^child_key, :branch_absent, _, _}
  end

  test "present or uncertain source prevents a storage-release result and further observation",
       f do
    child_key = ManagedMachine.key(f.child)

    for category <- [:identity_conflict, :unknown] do
      result = {:error, %Error{category: category, operation: :branch, evidence: :not_dispatched}}
      response(f, :branch_absent, f.parent, result)
      assert ^result = BranchObservation.storage_release(f.worker, f.parent, f.child)
      refute_received {:called, _, ^child_key, _, _, _}
    end
  end

  test "a replacement lookup cannot retarget the second observation", f do
    Agent.update(f.state, &%{&1 | replace: true})

    assert {:error, %{category: :unknown, evidence: :dispatch_uncertain}} =
             BranchObservation.storage_release(f.worker, f.parent, f.child)

    parent_key = ManagedMachine.key(f.parent)
    child_key = ManagedMachine.key(f.child)
    assert_received {:pin, :original}
    refute_received {:pin, :replacement}
    assert_received {:called, :original, ^parent_key, :branch_absent, _, _}
    assert_received {:called, :original, ^child_key, :branch_absent, _, _}
    refute_received {:called, :replacement, _, _, _, _}
  end

  test "an unavailable pin stays unavailable after a new owner appears", f do
    Agent.update(f.state, &%{&1 | owner: nil, live: nil})
    pinned = Target.pin(f.worker)
    Agent.update(f.state, &%{&1 | owner: :replacement, live: :replacement})

    assert {:error, %{category: :unknown}} =
             BranchObservation.resolution(pinned, f.parent, f.child, :deleted)

    assert_received {:pin, nil}
    refute_received {:pin, :replacement}
    refute_received {:called, :replacement, _, _, _, _}
  end

  test "another worker's record cannot enter the observation adapter", f do
    child = %{f.child | worker_id: "another-worker"}
    assert_raise Error, fn -> BranchObservation.retirement(f.worker, child) end
    refute_received {:called, _, _, _, _, _}
  end

  defp response(f, operation, record, result),
    do:
      Agent.update(
        f.state,
        &%{&1 | responses: Map.put(&1.responses, {operation, record.machine_name}, result)}
      )
end
