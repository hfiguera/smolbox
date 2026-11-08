defmodule SmolBox.Backend.EmbeddedPartialBranchCleanup do
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
    Call,
    Config,
    NativeGrowth,
    NativePartialBranchCleanup,
    NativePartialBranchCleanupResolutionResult,
    NativePartialBranchCleanupResult,
    NativePartialBranchDisposal,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded,
    Protocol,
    SDKIdentity
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @operations [:cleanup_partial_branch_disposal]

  def run(context, operation, %ManagedMachine{} = parent, %ManagedMachine{} = child, budget)
      when operation in @operations do
    {:ok, budget} = constrain(budget)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(child.backend_assignment, context.config, child.spec),
         {:ok, pin_budget} <- remaining(budget, deadline),
         do:
           coordinate(
             Call.pin(context, pin_budget),
             operation,
             parent,
             child,
             budget,
             &Call.run/3,
             deadline
           ),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  def run(_, _, _, _, _), do: failure(:validation, :not_dispatched)

  # Original collection precedes this control. Only the source is assigned;
  # partial-child inventory supplies no public Machine or completed creation.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    if scope?(context, operation, parent, child),
      do: exchange(context, operation, {parent, child}, {budget, call, deadline}),
      else: failure(:identity_conflict, :not_dispatched)
  end

  defp exchange(context, operation, {_parent, child} = records, {budget, call, deadline}) do
    with {:ok, stage} <- control_budget(budget, deadline),
         {:ok, request} <- request(operation, child),
         :ok <- within_budget(request, stage.max_request_bytes, :not_dispatched) do
      response = call.(context, request, stage)
      reply(context, operation, records, {request, response}, {budget, stage, call, deadline})
    end
  end

  defp reply(context, operation, records, {request, response}, {budget, stage, call, deadline}) do
    if resolution_reply?(context, operation, response, stage) do
      {:ok, outcome, @empty, nil} = response

      case unused_budget(budget, request, outcome, deadline) do
        {:ok, rest} ->
          exchange(context, :resolve_partial_branch_cleanup, records, {rest, call, deadline})

        error ->
          error
      end
    else
      observe(context, operation, records, {request, response}, {stage, call, deadline})
    end
  end

  defp observe(context, operation, {parent, child}, {request, response}, {budget, call, deadline}) do
    with {:ok, proof, outcome} <- decode(response, operation, child, budget.max_response_bytes),
         {:ok, _} <- after_response(operation, budget, deadline),
         do:
           finish(
             context,
             operation,
             parent,
             child,
             proof,
             {request, outcome},
             {budget, call, deadline}
           ),
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  # run/5 already requires an approved full configuration. This predicate also
  # serves transport-independent coordination peers without approving a package.
  @doc false
  def resolution_supported?(%{config: %Config{} = config}) do
    sdk = Config.sdk_identity(config)

    SDKIdentity.valid?(sdk) and
      match?(%{"branches" => 1, "partial_cleanup_resolution" => 1}, sdk["feature_versions"])
  end

  def resolution_supported?(_), do: false

  defp resolution_reply?(
         context,
         :cleanup_partial_branch_disposal,
         {:ok, %{"result" => "error", "dispatch" => "not_dispatched"} = outcome, @empty, nil},
         budget
       ),
       do:
         resolution_supported?(context) and fits?(outcome, budget.max_response_bytes) and
           Protocol.valid_outcome?(outcome, 2)

  defp resolution_reply?(_, _, _, _), do: false

  defp unused_budget(budget, request, outcome, deadline) do
    input = budget.max_request_bytes - size(request)
    output = budget.max_response_bytes - size(outcome)

    if input > 0 and output > 0,
      do: remaining(%{budget | max_request_bytes: input, max_response_bytes: output}, deadline),
      else: failure(:output_limit, :not_dispatched)
  end

  defp control_budget(budget, deadline) do
    with {:ok, budget} <- remaining(budget, deadline),
         do: Budget.constrain(budget, max_request_bytes: 32 * 1024, max_response_bytes: 96 * 1024)
  end

  defp scope?(context, operation, parent, child),
    do:
      operation in @operations and pinned?(context) and
        NativePartialBranchDisposal.pending?(parent, child) and
        source_context?(context, parent) and mode?(operation, child) and
        child.branch.native_authority.partial_disposal.platform == platform(context)

  defp pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  defp mode?(_, child),
    do:
      match?(
        %NativePartialBranchDisposal{
          proof: nil,
          cleanup: %NativePartialBranchCleanup{proof: nil, unneeded: nil}
        },
        child.branch.native_authority.partial_disposal
      )

  defp request(operation, child),
    do:
      {:ok,
       %{
         "operation" => Atom.to_string(operation),
         "request" => child.branch.native_authority.partial_disposal.cleanup.request
       }}

  defp decode(
         {:ok, %{"result" => "partial_branch_disposal_cleaned", "proof" => wire} = outcome,
          @empty, nil},
         operation,
         child,
         maximum
       )
       when operation == :cleanup_partial_branch_disposal do
    with :ok <- within_budget(outcome, maximum, :dispatch_uncertain),
         true <- Protocol.valid_outcome?(outcome, 2),
         true <-
           PartialBranchDisposalCleanup.matches?(
             wire,
             child.branch.native_authority.partial_disposal.cleanup.request
           ),
         {:ok, proof} <- PartialBranchDisposalCleanup.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode(
         {:ok, %{"result" => "partial_branch_cleanup_unneeded", "proof" => wire} = outcome,
          @empty, nil},
         :resolve_partial_branch_cleanup,
         child,
         maximum
       ) do
    with :ok <- within_budget(outcome, maximum, :dispatch_uncertain),
         true <- Protocol.valid_outcome?(outcome, 2),
         true <-
           PartialBranchDisposalCleanupUnneeded.matches?(
             wire,
             child.branch.native_authority.partial_disposal.cleanup.request
           ),
         {:ok, proof} <- PartialBranchDisposalCleanupUnneeded.from_wire(wire),
         do: {:ok, proof, outcome},
         else: (
           {:error, %Error{}} = error -> error
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, _, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp finish(context, _, parent, child, proof, transfer, stage) do
    case PartialBranchDisposal.from_wire(proof.disposal) do
      {:ok, disposal} ->
        EmbeddedBranchSourceObservation.finish(
          context,
          disposal,
          transfer,
          stage,
          &build_result(&1, proof, parent, child)
        )

      _ ->
        failure(:identity_conflict, :dispatch_uncertain)
    end
  end

  defp build_result(source, %PartialBranchDisposalCleanupUnneeded{} = proof, parent, child) do
    result = %NativePartialBranchCleanupResolutionResult{
      version: child.version,
      source: source,
      proof: proof
    }

    if NativePartialBranchCleanupResolutionResult.bound?(result, parent, child),
      do: {:ok, result},
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp build_result(source, %PartialBranchDisposalCleanup{} = proof, parent, child) do
    result = %NativePartialBranchCleanupResult{
      version: child.version,
      source: source,
      proof: proof
    }

    if NativePartialBranchCleanupResult.bound?(result, parent, child),
      do: {:ok, result},
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp after_response(_operation, budget, deadline) do
    case remaining(budget, deadline) do
      {:error, %Error{} = error} ->
        {:error, %{error | evidence: :dispatch_uncertain}}

      result ->
        result
    end
  end

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 64 * 1024,
        max_response_bytes: 192 * 1024
      )

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: constrain(%{budget | timeout_ms: min(timeout, budget.timeout_ms)}),
      else: failure(:expired, :not_dispatched)
  end

  defp platform(context), do: Atom.to_string(context.config.platform)
  defp fits?(value, maximum), do: size(value) <= maximum
  defp size(value), do: byte_size(Jason.encode!(value)) + 1024

  defp within_budget(value, limit, evidence),
    do: if(fits?(value, limit), do: :ok, else: failure(:output_limit, evidence))

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
