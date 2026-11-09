defmodule SmolBox.Backend.EmbeddedUnbootedBranchBackendTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Backend.{Budget, Embedded, EmbeddedContext, EmbeddedUnbootedBranchDisposal, HTTP}

  alias SmolBox.Embedded.{
    NativeGrowth,
    NativeUnbootedBranchDisposalResult,
    UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate
  }

  alias SmolBox.Store.{Memory, NativeUnbootedBranchDisposalContract}

  alias NativeUnbootedBranchDisposalContract, as: Contract

  @budget %Budget{timeout_ms: 5000, max_request_bytes: 131_072, max_response_bytes: 131_072}
  @operations [
    :inspect_unbooted_branch_disposal,
    :dispose_unbooted_branch,
    :resolve_unbooted_branch_disposal
  ]
  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp fixture(accepted \\ false, hold \\ true, provenance \\ "deleted") do
    store = start_supervised!(Memory, id: make_ref())
    {parent, child, completion, usage} = Contract.prepare(Memory, store, hold)

    candidate = %{
      "schema" => 1,
      "creation" => child.branch.native_authority.request,
      "publication" => completion.completion.publication,
      "preparation_sha256" => String.duplicate("f", 64)
    }

    candidate =
      Map.put(candidate, "proof_sha256", UnbootedBranchDisposalCandidate.proof_digest(candidate))

    assert {:ok, candidate} = UnbootedBranchDisposalCandidate.from_wire(candidate)

    {parent, child, result} =
      if accepted do
        {:ok, child} = Contract.accept(Memory, store, parent, child, child.version, 1103)

        {Contract.fetch(Memory, store, parent), child,
         Contract.result(child, completion, provenance)}
      else
        {parent, child, nil}
      end

    {:ok, identity} = NativeGrowth.current_identity(parent)
    {:ok, history} = NativeGrowth.transitions(parent)

    context = %EmbeddedContext{
      config: struct(SmolBox.Embedded.Config, platform: :macos),
      server: self(),
      pinned: true,
      quiesced: true,
      epoch: get_in(candidate.publication, ~w(change child_origin intent epoch)),
      assignment: parent.backend_assignment,
      identity: identity,
      history: history,
      spec: parent.spec,
      profile: parent.spec.profile,
      name: parent.machine_name
    }

    {store, parent, child, candidate, result, usage, context}
  end

  defp coordinate(context, operation, parent, child, call, budget \\ @budget, deadline \\ nil),
    do:
      EmbeddedUnbootedBranchDisposal.coordinate(
        context,
        operation,
        parent,
        child,
        budget,
        call,
        deadline
      )

  defp response(%UnbootedBranchDisposalCandidate{} = candidate),
    do:
      {:ok,
       %{
         "result" => "unbooted_branch_disposal_candidate",
         "candidate" => UnbootedBranchDisposalCandidate.to_wire(candidate)
       }, empty(), nil}

  defp response(%NativeUnbootedBranchDisposalResult{} = result),
    do:
      {:ok,
       %{
         "result" => "unbooted_branch_disposed",
         "proof" => UnbootedBranchDisposal.to_wire(result.proof)
       }, empty(), nil}

  defp observation(context, result),
    do:
      {:ok,
       %{
         "result" => "observed",
         "observation" => %{
           "resources" => EmbeddedContext.resources(context),
           "state" => Atom.to_string(result.source.state),
           "pid_identity" => result.source.backend_identity.pid_identity
         }
       }, empty(), nil}

  test "positive selection binds original helper source and complete frozen child without changing the store" do
    for hold <- [true, false] do
      {store, parent, child, candidate, _, usage, context} = fixture(false, hold)

      assert {:ok, ^candidate} =
               coordinate(context, :inspect_unbooted_branch_disposal, parent, child, fn actual,
                                                                                        request,
                                                                                        budget ->
                 assert actual == context

                 assert request == %{
                          "operation" => "inspect_unbooted_branch_disposal",
                          "request" => child.branch.native_authority.request,
                          "quiesced" => true
                        }

                 assert budget.timeout_ms <= 30_000 and budget.max_response_bytes <= 64 * 1024
                 response(candidate)
               end)

      assert Contract.fetch(Memory, store, child) == child
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    end
  end

  test "accepted disposal and observation-only resolution inspect the real evolved source and never invent child readiness" do
    for operation <- [:dispose_unbooted_branch, :resolve_unbooted_branch_disposal],
        hold <- [true, false],
        provenance <- ["deleted", "resolved_absent"] do
      {_, parent, child, _, result, _, context} = fixture(true, hold, provenance)

      assert {:ok, actual} =
               coordinate(context, operation, parent, child, fn source, request, budget ->
                 assert budget.timeout_ms <= 30_000

                 case request["operation"] do
                   "inspect" ->
                     assert request["receipt"] == result.proof.publication["receipt"]
                     assert source.identity.receipt == request["receipt"]
                     assert source.history == context.history ++ [source.identity.transition]
                     observation(source, result)

                   _ ->
                     assert source == context and
                              request["operation"] == Atom.to_string(operation)

                     assert request["request"] == child.branch.native_authority.disposal.request
                     response(result)
                 end
               end)

      assert actual == result
      assert NativeUnbootedBranchDisposalResult.bound?(actual, parent, child)
      assert child.created_machine == nil and child.branch.native_authority.completion == nil
    end
  end

  test "selection cannot cross pins scope source heads parent locks or accepted disposal" do
    {_, parent, child, _, _, _, context} = fixture()
    reject = fn _, _, _ -> flunk("invalid scope dispatched") end

    for wrong <- [
          %{context | pinned: false},
          %{context | quiesced: false},
          %{context | server: nil},
          %{context | epoch: nil},
          %{context | profile: %{context.profile | cpus: 8}},
          %{context | spec: child.spec}
        ] do
      assert {:error, %Error{evidence: :not_dispatched}} =
               coordinate(wrong, :inspect_unbooted_branch_disposal, parent, child, reject)
    end

    assert {:error, _} =
             coordinate(
               context,
               :inspect_unbooted_branch_disposal,
               %{parent | active_branch: nil},
               child,
               reject
             )

    assert {:error, _} = coordinate(context, :dispose_unbooted_branch, parent, child, reject)
    {_, parent, child, _, _, _, context} = fixture(true)

    assert {:error, _} =
             coordinate(context, :inspect_unbooted_branch_disposal, parent, child, reject)
  end

  test "candidate response requires exact current helper epoch platform plan source pid and full creation" do
    {_, parent, child, candidate, _, _, context} = fixture()

    for wrong <- [
          %{candidate | proof_sha256: String.duplicate("0", 64)},
          %{candidate | creation: put_in(candidate.creation, ~w(child name), "crossed")},
          nil
        ] do
      call = fn _, _, _ -> if wrong, do: response(wrong), else: {:ok, :absent} end

      assert {:error, _} =
               coordinate(context, :inspect_unbooted_branch_disposal, parent, child, call)
    end

    for wrong <- [
          %{context | epoch: String.duplicate("0", 32)},
          put_in(context.config.platform, :linux)
        ] do
      assert {:error, _} =
               coordinate(wrong, :inspect_unbooted_branch_disposal, parent, child, fn _, _, _ ->
                 response(candidate)
               end)
    end
  end

  test "bare results streams remote errors and crossed proofs cannot authorize source publication" do
    {_, parent, child, _, result, _, context} = fixture(true)

    for response <- [
          {:ok, :absent},
          {:ok, %{"result" => "unbooted_branch_disposed", "proof" => nil}, empty(), nil},
          put_elem(response(result), 2, %{empty() | stdout: "extra"}),
          put_elem(response(result), 3, %{"receipt" => "forbidden"}),
          {:error, %Error{category: :unknown, operation: :embedded}},
          response(%{result | proof: %{result.proof | proof_sha256: String.duplicate("0", 64)}})
        ] do
      assert {:error, _} =
               coordinate(context, :dispose_unbooted_branch, parent, child, fn _, request, _ ->
                 refute request["operation"] == "inspect"
                 response
               end)
    end
  end

  test "fresh source observation must preserve actual stopped or running identity and resources" do
    {_, parent, child, _, result, _, context} = fixture(true)

    for state <- [:running, :stopped] do
      expected =
        if state == :running,
          do: result,
          else: %{
            result
            | source: %{
                result.source
                | state: :stopped,
                  backend_identity: %{result.source.backend_identity | pid_identity: nil}
              }
          }

      assert {:ok, ^expected} =
               coordinate(context, :resolve_unbooted_branch_disposal, parent, child, fn source,
                                                                                        request,
                                                                                        _ ->
                 if request["operation"] == "inspect",
                   do: observation(source, expected),
                   else: response(expected)
               end)
    end

    for field <- ["pid_identity", "resources"] do
      assert {:error, %Error{evidence: :dispatch_uncertain}} =
               coordinate(context, :dispose_unbooted_branch, parent, child, fn source,
                                                                               request,
                                                                               _ ->
                 if request["operation"] == "inspect" do
                   {:ok, wire, bytes, nil} = observation(source, result)

                   wire =
                     if field == "pid_identity",
                       do: put_in(wire, ~w(observation pid_identity), [999, 999]),
                       else: update_in(wire, ~w(observation resources cpus), &(&1 + 1))

                   {:ok, wire, bytes, nil}
                 else
                   response(result)
                 end
               end)
    end
  end

  test "one deadline and aggregate transfer allowance cover proof and source observation" do
    {_, parent, child, candidate, _, _, context} = fixture()

    assert {:error, %Error{category: :expired}} =
             coordinate(
               context,
               :inspect_unbooted_branch_disposal,
               parent,
               child,
               fn _, _, _ -> flunk("expired probe dispatched") end,
               @budget,
               System.monotonic_time(:millisecond) - 1
             )

    assert {:error, %Error{evidence: :not_dispatched}} =
             coordinate(
               context,
               :inspect_unbooted_branch_disposal,
               parent,
               child,
               fn _, _, _ -> flunk("oversize probe dispatched") end,
               %{@budget | max_request_bytes: 1}
             )

    assert {:error, _} =
             coordinate(
               context,
               :inspect_unbooted_branch_disposal,
               parent,
               child,
               fn _, _, _ -> response(candidate) end,
               %{@budget | max_response_bytes: 1}
             )

    {_, parent, child, _, result, _, context} = fixture(true)
    {:ok, proof_outcome, _, _} = response(result)

    assert {:error, %Error{category: :output_limit}} =
             coordinate(
               context,
               :dispose_unbooted_branch,
               parent,
               child,
               fn _, request, _ ->
                 refute request["operation"] == "inspect"
                 response(result)
               end,
               %{@budget | max_response_bytes: byte_size(Jason.encode!(proof_outcome))}
             )
  end

  test "elapsed observation after a genuine disposal response preserves dispatch uncertainty" do
    {_, parent, child, _, result, _, context} = fixture(true)

    assert {:error, %Error{category: :expired, evidence: :dispatch_uncertain}} =
             coordinate(
               context,
               :dispose_unbooted_branch,
               parent,
               child,
               fn _, _, _ ->
                 Process.sleep(2000)
                 response(result)
               end,
               @budget,
               System.monotonic_time(:millisecond) + 1500
             )
  end

  test "native-only inventory stays feature gated and cannot activate HTTP or unsupported production contexts" do
    {_, parent, child, _, _, _, context} = fixture()

    for operation <- @operations do
      assert Keyword.fetch!(Backend.operations(), operation) == 3
      assert Embedded.supports_operation?(nil, operation)
      refute HTTP.supports_operation?(nil, operation)
      refute Embedded.supports_operation?(context, operation)

      assert {:error, %Error{evidence: :not_dispatched}} =
               Embedded.invoke(context, operation, [parent, child], @budget)
    end

    assert :ok = ManagedMachine.validate(parent)
  end
end
