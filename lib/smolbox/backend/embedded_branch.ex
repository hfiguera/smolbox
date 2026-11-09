defmodule SmolBox.Backend.EmbeddedBranch do
  @moduledoc false
  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedBranchSourceObservation,
    EmbeddedContext,
    EmbeddedReply,
    Features
  }

  alias SmolBox.Embedded.{
    BranchCompletion,
    BranchPublication,
    BranchReleaseTransition,
    Call,
    HeldBranchReleaseRequest,
    Identity,
    NativeBranchAuthority,
    NativeBranchReleaseResult,
    NativeBranchResult,
    NativeCollectedBranchPublication,
    NativeGrowth,
    Protocol
  }

  alias SmolBox.{Error, ManagedMachine}

  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  # Bounds one request envelope and the accepted/terminal envelope pair. The
  # protocol contract checks maximum-width IDs, sequences, credit and epochs.
  @wire_allowance 1024

  def run(context, operation, arguments, budget) do
    {:ok, budget} =
      Budget.constrain(budget,
        timeout_ms:
          if(operation in [:branch_inspect_child, :resolve_ready_branch],
            do: 30_000,
            else: 900_000
          )
      )

    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         [parent, child] <- records(context, operation, arguments),
         true <- Assignment.approved?(child.backend_assignment, context.config, child.spec),
         {:ok, remaining} <- remaining(budget, deadline),
         context = Call.pin(context, remaining),
         true <- is_pid(context.server) and context.epoch != nil do
      coordinate(context, mode(operation, child), parent, child, budget, &Call.run/3, deadline)
    else
      {:error, _} = error -> error
      _ -> failure(:unsupported_capability, :not_dispatched)
    end
  end

  # The source is the assigned authority for this two-machine operation. Release
  # receives only the child argument; the source context already carries its head
  # and complete material history, including any sibling publications.
  defp records(context, :branch_create, [parent, _] = records) do
    if source_context?(context, parent), do: records, else: :error
  end

  defp records(context, :resolve_ready_branch, [parent, _] = records) do
    if source_context?(context, parent), do: records, else: :error
  end

  defp records(context, :branch_release, [child]), do: [context, child]

  defp records(context, :branch_inspect_child, [child, held]) do
    if held == child.branch.spec.hold, do: [context.spec, child], else: :error
  end

  defp records(_, _, _), do: :error

  defp mode(:branch_inspect_child, %{branch: %{native_authority: %{release: nil}}}),
    do: :branch_lookup_creation

  defp mode(:resolve_ready_branch, _), do: :branch_resolve_creation

  defp mode(:branch_inspect_child, _), do: :branch_lookup_release
  defp mode(operation, _), do: operation

  # Transport-independent sequence used by run/4 after policy/pin approval.
  # A semantic peer can exercise it without enabling an unqualified SDK feature.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    budget = recovery_budget(operation, budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <- pinned?(context) and scope?(context, operation, parent, child),
         {:ok, request} <- request(operation, child),
         {:ok, response, budget} <- exchange(context, request, budget, call, deadline),
         {:ok, evidence} <- proof(operation, child, response),
         {:ok, source_context, child_context} <- promote(context, operation, child, evidence) do
      observations(
        {operation, parent, child, evidence},
        {source_context, child_context},
        {budget, call, deadline}
      )
    else
      {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
      _ -> failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  # A valid completion precedes these fresh observations. A later undispatched
  # inspection cannot prove that the whole branch operation was undispatched,
  # nor authorize replay, activation or release of its retained resources.
  defp observations(
         {operation, parent, child, evidence},
         {source_context, child_context},
         {budget, call, deadline}
       ) do
    source_request = %{
      "operation" => "branch_preflight",
      "receipt" => source_context.identity.receipt
    }

    with {:ok, source_response, budget} <-
           exchange(source_context, source_request, budget, call, deadline, 16_384),
         {:ok, source} <- observe(source_context, :branch_source, source_request, source_response),
         child_request = %{"operation" => "inspect", "receipt" => child_context.identity.receipt},
         {:ok, child_response, budget} <-
           exchange(child_context, child_request, budget, call, deadline, 16_384),
         {:ok, observed} <-
           observe(child_context, :inspect_machine, child_request, child_response),
         {:ok, _} <- remaining(budget, deadline) do
      result(operation, parent, child, evidence, source, observed)
    else
      {:error, %Error{} = error} ->
        {:error, %{error | operation: :branch, evidence: :dispatch_uncertain}}

      _ ->
        failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  defp request(:branch_create, %{branch: %{state: :dispatching, native_authority: authority}}),
    do: {:ok, %{"operation" => "create_branch", "request" => authority.request}}

  defp request(:branch_release, %{
         branch: %{state: :release_dispatching, native_authority: authority}
       }),
       do:
         {:ok,
          %{
            "operation" => "release_held_branch",
            "request" => HeldBranchReleaseRequest.from_authority(authority)
          }}

  defp request(:branch_resolve_creation, %{
         branch: %{state: :unknown, native_authority: authority}
       }),
       do:
         {:ok,
          %{
            "operation" => "resolve_ready_branch_completion",
            "request" => authority.request,
            "quiesced" => true
          }}

  defp request(:branch_lookup_creation, %{branch: %{state: :unknown, native_authority: authority}}),
       do: {:ok, %{"operation" => "inspect_branch_completion", "request" => authority.request}}

  defp request(:branch_lookup_release, %{branch: %{state: :unknown, native_authority: authority}}),
       do:
         {:ok,
          %{
            "operation" => "qualify_held_branch_release",
            "request" => HeldBranchReleaseRequest.from_authority(authority)
          }}

  defp request(_, _), do: failure(:identity_conflict, :not_dispatched)

  defp pinned?(context), do: context.pinned and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  defp scope?(context, :branch_create, parent, child) do
    ManagedMachine.validate(parent) == :ok and ManagedMachine.validate(child) == :ok and
      source_context?(context, parent) and NativeBranchAuthority.child?(child) and
      child.branch.source == ManagedMachine.key(parent) and
      child.branch.native_authority.request["source"] == context.identity.receipt and
      parent.active_branch == child.id and child.branch.state == :dispatching
  end

  defp scope?(context, :branch_resolve_creation, parent, child) do
    context.quiesced and ManagedMachine.validate(parent) == :ok and
      source_context?(context, parent) and parent.active_branch == child.id and
      parent.worker_id == child.worker_id and parent.worker_generation == child.worker_generation and
      scope?(context, :branch_lookup_creation, parent, child)
  end

  defp scope?(context, :branch_release, _parent, child) do
    with :ok <- ManagedMachine.validate(child),
         true <- NativeBranchAuthority.child?(child),
         %{source: source, transition: nil} <- child.branch.native_authority.release do
      child.branch.state == :release_dispatching and
        child.branch.source == {context.spec.scope, context.spec.id} and
        source == context.identity.receipt and context.profile == child.spec.profile and
        context.spec.artifact == child.spec.artifact
    else
      _ -> false
    end
  end

  defp scope?(context, operation, _parent, child)
       when operation in [:branch_lookup_creation, :branch_lookup_release] do
    ManagedMachine.validate(child) == :ok and NativeBranchAuthority.child?(child) and
      child.branch.state == :unknown and
      child.branch.source == {context.spec.scope, context.spec.id} and
      context.profile == child.spec.profile and context.spec.artifact == child.spec.artifact and
      lookup_source?(context, operation, child.branch.native_authority)
  end

  defp scope?(_, _, _, _), do: false

  defp lookup_source?(
         context,
         :branch_lookup_creation,
         %{completion: nil, release: nil} = authority
       ),
       do: lookup_creation_source?(context, authority)

  defp lookup_source?(context, :branch_lookup_release, %{
         release: %{source: source, transition: nil}
       }),
       do: source == context.identity.receipt

  defp lookup_source?(_, _, _), do: false

  defp lookup_creation_source?(context, %{collected_publication: nil} = authority),
    do: authority.request["source"] == context.identity.receipt

  defp lookup_creation_source?(context, %{
         collected_publication: %NativeCollectedBranchPublication{
           proof: %BranchPublication{} = proof
         }
       }),
       do:
         context.identity.receipt == proof.receipt and context.identity.transition == proof and
           List.last(context.history || []) == proof

  defp lookup_creation_source?(_, _), do: false

  defp proof(
         operation,
         child,
         {:ok, %{"result" => kind, "completion" => wire} = outcome, @empty, nil}
       )
       when operation in [:branch_create, :branch_lookup_creation, :branch_resolve_creation] do
    with true <- kind == result_kind(operation) and Protocol.valid_outcome?(outcome, 2),
         {:ok, proof} <- BranchCompletion.from_wire(wire),
         true <- BranchCompletion.matches?(wire, child.branch.native_authority.request),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp proof(
         operation,
         child,
         {:ok, %{"result" => kind, "transition" => wire} = outcome, @empty, nil}
       )
       when operation in [:branch_release, :branch_lookup_release] do
    with true <- kind == result_kind(operation) and Protocol.valid_outcome?(outcome, 2),
         true <-
           HeldBranchReleaseRequest.matches?(
             wire,
             HeldBranchReleaseRequest.from_authority(child.branch.native_authority)
           ),
         {:ok, proof} <- BranchReleaseTransition.from_wire(wire),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp proof(_, _, {:ok, %{"result" => "error"} = outcome, @empty, nil} = result) do
    if Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, result),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp proof(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp result_kind(:branch_create), do: "branch_created"
  defp result_kind(:branch_release), do: "held_branch_released"
  defp result_kind(:branch_resolve_creation), do: "branch_completion_presence"
  defp result_kind(:branch_lookup_creation), do: "branch_completion_presence"
  defp result_kind(:branch_lookup_release), do: "held_branch_release_presence"

  defp promote(context, operation, child, proof)
       when operation in [:branch_create, :branch_lookup_creation, :branch_resolve_creation] do
    with true <-
           proof.publication["change"]["platform"] == Atom.to_string(context.config.platform),
         true <-
           operation != :branch_resolve_creation or
             get_in(proof.publication, ~w(change child_origin intent epoch)) == context.epoch,
         {:ok, publication} <- BranchPublication.from_wire(proof.publication),
         {:ok, source_context} <-
           EmbeddedBranchSourceObservation.promote_publication(context, publication),
         authority = %{child.branch.native_authority | completion: proof},
         {:ok, child_history} <-
           NativeBranchAuthority.transitions(%{
             child
             | branch: %{child.branch | native_authority: authority}
           }),
         child_identity = %Identity{
           receipt: proof.child,
           transition: List.last(child_history),
           material_history: history_or_nil(child_history)
         },
         true <- Identity.valid?(child_identity) do
      {:ok, source_context, child_context(context, child, child_identity, child_history)}
    else
      _ -> failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  defp promote(context, operation, child, proof)
       when operation in [:branch_release, :branch_lookup_release] do
    identity = %Identity{receipt: proof.receipt, transition: proof, material_history: [proof]}

    if Identity.valid?(identity) and
         HeldBranchReleaseRequest.platform(
           HeldBranchReleaseRequest.from_authority(child.branch.native_authority)
         ) == Atom.to_string(context.config.platform),
       do: {:ok, context, child_context(context, child, identity, [proof])},
       else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp child_context(context, child, identity, history),
    do: %{
      context
      | assignment: child.backend_assignment,
        spec: child.spec,
        profile: child.spec.profile,
        name: child.machine_name,
        identity: identity,
        history: history,
        growth: nil,
        capture: nil,
        export: nil,
        managed_machine: nil,
        branch_retirement: nil,
        branch_deletion: nil
    }

  defp observe(context, operation, request, {:ok, outcome, @empty, nil} = result) do
    if Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(context, operation, request, result),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp observe(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp result(operation, parent, child, proof, source, observed)
       when operation in [:branch_create, :branch_lookup_creation, :branch_resolve_creation] do
    result = %NativeBranchResult{completion: proof, source: source, child: observed}

    if NativeBranchResult.bound?(result, parent, child),
      do: {:ok, result},
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp result(operation, _, child, proof, source, observed)
       when operation in [:branch_release, :branch_lookup_release] do
    result = %NativeBranchReleaseResult{transition: proof, source: source, child: observed}

    if NativeBranchReleaseResult.bound?(result, child.branch.native_authority),
      do: {:ok, result},
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp history_or_nil([]), do: nil
  defp history_or_nil(history), do: history

  # Each successful reply consumes encoded payload plus conservative framing
  # before another stage. A lost/error reply ends the sequence.
  defp exchange(context, request, budget, call, deadline, output_limit \\ 68 * 1024) do
    with :ok <- transfer_available(budget),
         {:ok, stage} <- remaining(budget, deadline),
         {:ok, stage} <- transfer_budget(stage, request, output_limit),
         :ok <- fits_transfer(request, stage.max_request_bytes),
         {:ok, outcome, @empty, nil} = response <- call.(context, request, stage),
         :ok <- fits_transfer(outcome, stage.max_response_bytes),
         {:ok, _} <- remaining(stage, deadline) do
      {:ok, response,
       %{
         budget
         | max_request_bytes:
             budget.max_request_bytes - byte_size(Jason.encode!(request)) - @wire_allowance,
           max_response_bytes:
             budget.max_response_bytes - byte_size(Jason.encode!(outcome)) - @wire_allowance
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  defp transfer_available(budget),
    do:
      if(
        budget.max_request_bytes > @wire_allowance and budget.max_response_bytes > @wire_allowance,
        do: :ok,
        else: failure(:output_limit, :dispatch_uncertain)
      )

  defp fits_transfer(value, maximum),
    do:
      if(byte_size(Jason.encode!(value)) + @wire_allowance <= maximum,
        do: :ok,
        else: failure(:output_limit, :dispatch_uncertain)
      )

  defp transfer_budget(budget, %{"operation" => name}, maximum)
       when name in ~w(branch_preflight inspect),
       do: Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: maximum)

  defp transfer_budget(budget, _, maximum),
    do: Budget.constrain(budget, max_response_bytes: maximum)

  defp recovery_budget(:branch_resolve_creation, budget) do
    {:ok, budget} =
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 28 * 1024,
        max_response_bytes: 100 * 1024
      )

    budget
  end

  defp recovery_budget(_, budget), do: budget

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout),
      else: failure(:expired, :dispatch_uncertain)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
