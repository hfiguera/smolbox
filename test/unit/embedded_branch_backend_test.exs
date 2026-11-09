defmodule SmolBox.EmbeddedBranchBackendTest do
  use ExUnit.Case, async: true

  alias SmolBox.Backend.{
    Budget,
    Embedded,
    EmbeddedBranch,
    EmbeddedContext,
    EmbeddedOperation,
    Reference
  }

  alias SmolBox.Embedded.{BranchCompletion, BranchReleaseTransition, Config, NativeGrowth}
  alias SmolBox.{Error, MachineSpec, ManagedMachine}
  alias SmolBox.Runtime.{BranchObservation, Target}
  alias SmolBox.Store.{Contract, Memory, NativeBranchContract, NativeBranchReleaseContract}

  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @budget %Budget{timeout_ms: 5000, max_request_bytes: 131_072, max_response_bytes: 131_072}
  @configuration %{
    "network" => %{"enabled" => false, "hosts" => [], "cidrs" => []},
    "ports" => [],
    "backend" => nil
  }

  defmodule LookupAdapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, operation), do: operation == :branch_inspect_child
    def pin(context, _budget), do: {:ok, context}
    def assign(context, parent), do: {:ok, %{context | parent: parent}}

    def invoke(context, :branch_inspect_child, [child, _held], budget),
      do:
        EmbeddedBranch.coordinate(
          context.core,
          context.mode,
          context.parent,
          child,
          budget,
          context.call
        )
  end

  defp fixture(operation, hold \\ true) do
    store = start_supervised!(Memory)

    {parent, pending, result} =
      case operation do
        :branch_create ->
          {parent, child, result} = NativeBranchContract.prepare(Memory, store, hold)

          assert {:ok, pending} =
                   NativeBranchContract.advance(
                     Memory,
                     store,
                     parent,
                     child,
                     :accepted,
                     :dispatching,
                     1101
                   )

          {parent, pending, result}

        :branch_release ->
          {parent, child, result, _} = NativeBranchReleaseContract.prepare(Memory, store)

          assert {:ok, pending} =
                   NativeBranchReleaseContract.advance(Memory, store, child, :dispatching, 1201)

          {parent, pending, result}
      end

    assert {:ok, parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, identity} = NativeGrowth.current_identity(parent)
    assert {:ok, history} = NativeGrowth.transitions(parent)

    context = %EmbeddedContext{
      config: struct(Config, platform: :macos),
      server: self(),
      pinned: true,
      epoch: String.duplicate("a", 32),
      assignment: parent.backend_assignment,
      identity: identity,
      history: history,
      spec: parent.spec,
      profile: parent.spec.profile,
      name: parent.machine_name
    }

    {store, context, parent, pending, result}
  end

  defp uncertain(:branch_create, store, parent, child),
    do: NativeBranchContract.advance(Memory, store, parent, child, :dispatching, :unknown, 1202)

  defp uncertain(:branch_release, store, _parent, child),
    do: NativeBranchReleaseContract.advance(Memory, store, child, :unknown, 1202)

  defp reply(:branch_create, result),
    do: %{
      "result" => "branch_created",
      "completion" => BranchCompletion.to_wire(result.completion)
    }

  defp reply(:branch_release, result),
    do: %{
      "result" => "held_branch_released",
      "transition" => BranchReleaseTransition.to_wire(result.transition)
    }

  defp reply(:branch_lookup_creation, result),
    do: %{
      "result" => "branch_completion_presence",
      "completion" => BranchCompletion.to_wire(result.completion)
    }

  defp reply(:branch_lookup_release, result),
    do: %{
      "result" => "held_branch_release_presence",
      "transition" => BranchReleaseTransition.to_wire(result.transition)
    }

  defp observed(machine),
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
        "configuration" => @configuration
      }
    }

  defp peer(operation, result, transform \\ fn _, response -> response end) do
    fn context, request, budget ->
      send(self(), {:called, context, request, budget})

      response =
        case request["operation"] do
          name
          when name in [
                 "create_branch",
                 "release_held_branch",
                 "inspect_branch_completion",
                 "qualify_held_branch_release"
               ] ->
            reply(operation, result)

          "branch_preflight" ->
            observed(result.source)

          "inspect" ->
            observed(result.child)
        end

      transform.(request, {:ok, response, @empty, nil})
    end
  end

  for hold <- [true, false] do
    test "held=#{hold} creation binds original proof and two current observations to one owner then commits atomically" do
      {store, context, parent, child, evidence} = fixture(:branch_create, unquote(hold))

      assert {:ok, result} =
               EmbeddedBranch.coordinate(
                 context,
                 :branch_create,
                 parent,
                 child,
                 %{@budget | timeout_ms: 900_000},
                 peer(:branch_create, evidence)
               )

      assert result.completion == evidence.completion
      assert result.source.backend_identity == evidence.source.backend_identity
      assert result.child.backend_identity == evidence.child.backend_identity
      assert_receive {:called, original, %{"operation" => "create_branch"}, first}

      assert_receive {:called, source,
                      %{"operation" => "branch_preflight", "receipt" => source_receipt}, second}

      assert_receive {:called, leaf, %{"operation" => "inspect", "receipt" => child_receipt},
                      third}

      assert source_receipt == evidence.completion.publication["receipt"]
      assert child_receipt == evidence.completion.child
      assert original.identity == context.identity
      assert source.assignment == parent.backend_assignment
      assert leaf.assignment == child.backend_assignment
      assert source.history == evidence.source.backend_identity.material_history

      for scoped <- [original, source, leaf],
          do: assert({scoped.server, scoped.epoch} == {context.server, context.epoch})

      assert first.timeout_ms >= second.timeout_ms and second.timeout_ms >= third.timeout_ms
      assert first.timeout_ms > 30_000
      assert second.timeout_ms <= 30_000 and third.timeout_ms <= 30_000
      assert second.max_response_bytes <= 16_384 and third.max_response_bytes <= 16_384

      assert {:ok, saved} =
               NativeBranchContract.advance(
                 Memory,
                 store,
                 parent,
                 child,
                 :dispatching,
                 {:native_complete, result},
                 1102
               )

      assert saved.branch.state == if(unquote(hold), do: :held, else: :ready)
      assert saved.observed_machine == result.child
      assert {:ok, source} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert source.active_branch == nil and source.observed_machine == result.source
    end
  end

  test "explicit held release uses current source history and child proof before paired completion" do
    {store, context, parent, child, evidence} = fixture(:branch_release)

    assert {:ok, result} =
             EmbeddedBranch.coordinate(
               context,
               :branch_release,
               context,
               child,
               @budget,
               peer(:branch_release, evidence)
             )

    assert result.transition == evidence.transition
    assert result.source.backend_identity == evidence.source.backend_identity
    assert result.child.backend_identity == evidence.child.backend_identity
    assert_receive {:called, _, %{"operation" => "release_held_branch"}, _}
    assert_receive {:called, source, %{"operation" => "branch_preflight"}, _}
    assert_receive {:called, leaf, %{"operation" => "inspect"}, _}
    assert source.identity == context.identity and source.history == context.history
    assert leaf.history == [result.transition]
    assert leaf.assignment == child.backend_assignment
    assert {leaf.server, leaf.epoch} == {context.server, context.epoch}
    assert {:ok, usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, released} =
             NativeBranchReleaseContract.advance(
               Memory,
               store,
               child,
               {:native_complete, result},
               1202
             )

    assert released.branch.state == :released
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  for {operation, mode, lookup} <- [
        {:branch_create, :branch_lookup_creation, "inspect_branch_completion"},
        {:branch_release, :branch_lookup_release, "qualify_held_branch_release"}
      ] do
    test "#{operation} kept resolution consumes retained result and current positives through the source-scoped backend" do
      operation = unquote(operation)
      mode = unquote(mode)
      {store, context, parent, child, evidence} = fixture(operation)

      assert {:ok, unknown} = uncertain(operation, store, parent, child)

      assert {:ok, parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])

      reference = %Reference{
        adapter: LookupAdapter,
        kind: :embedded,
        id: parent.worker_id,
        context: %{core: context, mode: mode, parent: nil, call: peer(mode, evidence)},
        budget: @budget
      }

      target = %Target{kind: :embedded, id: parent.worker_id, connection: reference}

      assert {:ok, [source, result]} =
               BranchObservation.resolution(target, parent, unknown, :keep)

      assert source == result.source
      assert_receive {:called, _, %{"operation" => name}, _}
      assert name == unquote(lookup)
      assert_receive {:called, _, %{"operation" => "branch_preflight"}, _}
      assert_receive {:called, _, %{"operation" => "inspect"}, _}
      refute_receive {:called, _, _, _}

      assert {:ok, saved} =
               Memory.machine(store, :branch_resolve, [
                 ManagedMachine.key(parent),
                 Contract.guard(parent),
                 child.id,
                 source,
                 result,
                 1203
               ])

      assert saved.branch.state ==
               unquote(if(operation == :branch_create, do: :held, else: :released))

      assert saved.observed_machine == result.child
    end

    test "#{operation} missing retained completion stays uncertain and never authorizes another request" do
      operation = unquote(operation)
      mode = unquote(mode)
      {store, context, parent, child, evidence} = fixture(operation)

      assert {:ok, unknown} = uncertain(operation, store, parent, child)

      assert {:ok, parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])

      outcome =
        unquote(
          Macro.escape(
            if(operation == :branch_create,
              do: %{"result" => "branch_completion_presence", "completion" => nil},
              else: %{"result" => "held_branch_release_presence", "transition" => nil}
            )
          )
        )

      callback = peer(mode, evidence, fn _, _ -> {:ok, outcome, @empty, nil} end)

      assert {:error, %Error{evidence: :dispatch_uncertain}} =
               EmbeddedBranch.coordinate(context, mode, parent, unknown, @budget, callback)

      assert_receive {:called, _, %{"operation" => name}, _}
      assert name == unquote(lookup)
      refute_receive {:called, _, _, _}
      assert {:ok, ^unknown} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])
    end
  end

  for operation <- [:branch_create, :branch_release] do
    test "#{operation} rejects missing proof extra output and disqualified transport before probing" do
      operation = unquote(operation)
      {_, context, parent, child, result} = fixture(operation)

      for response <- [
            {:ok, %{"result" => "qualified"}, @empty, nil},
            {:ok, reply(operation, result), %{@empty | stdout: "extra"}, nil},
            {:ok, reply(operation, result), @empty,
             %Error{category: :unknown, operation: :branch}}
          ] do
        assert {:error, %Error{evidence: :dispatch_uncertain}} =
                 EmbeddedBranch.coordinate(
                   context,
                   operation,
                   parent,
                   child,
                   @budget,
                   peer(operation, result, fn _, _ -> response end)
                 )

        assert_receive {:called, _, _, _}
        refute_receive {:called, _, _, _}
      end
    end

    test "#{operation} requires exact resources original births distinct current children and both positives" do
      operation = unquote(operation)
      {_, context, parent, child, result} = fixture(operation)

      for changed <- [
            put_in(result.source.backend_identity.pid_identity, [123, 457]),
            put_in(
              result.child.backend_identity.pid_identity,
              result.source.backend_identity.pid_identity
            ),
            %{result | source: %{result.source | cpus: 2}},
            %{
              result
              | child: %{
                  result.child
                  | state: :stopped,
                    backend_identity: %{result.child.backend_identity | pid_identity: nil}
                }
            }
          ] do
        assert {:error, %Error{evidence: :dispatch_uncertain}} =
                 EmbeddedBranch.coordinate(
                   context,
                   operation,
                   parent,
                   child,
                   @budget,
                   peer(operation, changed)
                 )
      end
    end
  end

  test "expired absolute deadline unpinned owner crossed source and wrong platform cannot authorize dispatch or completion" do
    {_, context, parent, child, result} = fixture(:branch_create)

    for scoped <- [
          %{context | pinned: false},
          %{context | epoch: nil},
          %{context | name: "different"}
        ] do
      assert {:error, _} =
               EmbeddedBranch.coordinate(
                 scoped,
                 :branch_create,
                 parent,
                 child,
                 @budget,
                 peer(:branch_create, result)
               )

      refute_receive {:called, _, _, _}
    end

    assert {:error, %Error{category: :expired}} =
             EmbeddedBranch.coordinate(
               context,
               :branch_create,
               parent,
               child,
               @budget,
               peer(:branch_create, result),
               System.monotonic_time(:millisecond)
             )

    refute_receive {:called, _, _, _}
    context = %{context | config: %{context.config | platform: :linux}}

    assert {:error, _} =
             EmbeddedBranch.coordinate(
               context,
               :branch_create,
               parent,
               child,
               @budget,
               peer(:branch_create, result)
             )

    assert_receive {:called, _, %{"operation" => "create_branch"}, _}
    refute_receive {:called, _, _, _}
  end

  test "proof and both positive observations spend one absolute budget" do
    {_, context, parent, child, result} = fixture(:branch_create)

    for delayed <- ["create_branch", "inspect"] do
      callback =
        peer(:branch_create, result, fn request, response ->
          if request["operation"] == delayed, do: Process.sleep(2000)
          response
        end)

      deadline = System.monotonic_time(:millisecond) + 1500

      assert {:error, %Error{category: :expired, operation: :branch}} =
               EmbeddedBranch.coordinate(
                 context,
                 :branch_create,
                 parent,
                 child,
                 @budget,
                 callback,
                 deadline
               )

      assert_receive {:called, _, %{"operation" => "create_branch"}, _}

      if delayed == "inspect" do
        assert_receive {:called, _, %{"operation" => "branch_preflight"}, _}
        assert_receive {:called, _, %{"operation" => "inspect"}, _}
      end

      refute_receive {:called, _, _, _}
    end
  end

  test "helper error terminals retain their public category and dispatch evidence" do
    {_, context, parent, child, result} = fixture(:branch_create)

    for {code, category, dispatch, evidence} <- [
          {"overload", :admission_exhausted, "not_dispatched", :not_dispatched},
          {"deadline", :expired, "may_have_dispatched", :dispatch_uncertain}
        ] do
      outcome = %{"result" => "error", "code" => code, "dispatch" => dispatch}
      callback = peer(:branch_create, result, fn _, _ -> {:ok, outcome, @empty, nil} end)

      assert {:error, %Error{category: ^category, evidence: ^evidence, operation: :branch}} =
               EmbeddedBranch.coordinate(
                 context,
                 :branch_create,
                 parent,
                 child,
                 @budget,
                 callback
               )

      assert_receive {:called, _, _, _}
      refute_receive {:called, _, _, _}
    end
  end

  for {operation, mode} <- [
        {:branch_create, :branch_create},
        {:branch_release, :branch_release},
        {:branch_create, :branch_lookup_creation},
        {:branch_release, :branch_lookup_release}
      ] do
    test "#{mode} keeps the whole branch uncertain when a later observation is not dispatched" do
      operation = unquote(operation)
      mode = unquote(mode)
      {store, context, parent, child, result} = fixture(operation)

      child =
        if unquote(mode in [:branch_lookup_creation, :branch_lookup_release]) do
          {:ok, unknown} = uncertain(operation, store, parent, child)
          unknown
        else
          child
        end

      assert {:ok, parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert {:ok, usage} = Memory.usage(store, parent.worker_id)

      for rejected <- ~w(branch_preflight inspect),
          response <- [
            {:error,
             %Error{
               category: :admission_exhausted,
               operation: :embedded,
               evidence: :not_dispatched
             }},
            {:ok, %{"result" => "error", "code" => "overload", "dispatch" => "not_dispatched"},
             @empty, nil}
          ] do
        callback =
          peer(mode, result, fn request, success ->
            if request["operation"] == rejected, do: response, else: success
          end)

        assert {:error,
                %Error{
                  category: :admission_exhausted,
                  operation: :branch,
                  evidence: :dispatch_uncertain
                }} =
                 EmbeddedBranch.coordinate(context, mode, parent, child, @budget, callback)

        assert_receive {:called, _, _, _}
        assert_receive {:called, _, %{"operation" => "branch_preflight"}, _}
        if rejected == "inspect", do: assert_receive({:called, _, %{"operation" => "inspect"}, _})
        refute_receive {:called, _, _, _}
        assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
        assert {:ok, ^parent} = Memory.machine(store, :fetch, [ManagedMachine.key(parent)])
        assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      end
    end
  end

  test "current public admission remains closed and branch assignments cannot fall back to fresh creation" do
    {_, context, parent, child, _} = fixture(:branch_create)
    refute Embedded.supports_operation?(context, :branch_create)
    refute Embedded.supports_operation?(context, :branch_release)

    assert {:error, %Error{evidence: :not_dispatched}} =
             EmbeddedBranch.run(context, :branch_create, [parent, child], @budget)

    # The private request builder must reject this structurally, even if a future
    # package qualifies the assignment. No missing artifact path may be dereferenced.
    branch_context = %{context | assignment: child.backend_assignment}

    for operation <- [:create, :create_prepared, :inspect_creation] do
      assert {:error, %Error{category: :identity_conflict}} =
               EmbeddedOperation.build(branch_context, operation, [struct(MachineSpec)], @budget)
    end

    refute_receive {:called, _, _, _}
  end
end
