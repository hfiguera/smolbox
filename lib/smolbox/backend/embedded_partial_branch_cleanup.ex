defmodule SmolBox.Backend.EmbeddedPartialBranchCleanup do
  @moduledoc false

  alias SmolBox.Backend.{Budget, EmbeddedBranchOperation, EmbeddedBranchSourceObservation}

  alias SmolBox.Embedded.{
    Config,
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

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @frame_overhead 1024
  @operations [:cleanup_partial_branch_disposal]

  # Original collection precedes this control. Only the source is assigned;
  # partial-child inventory supplies no public Machine or completed creation.
  def coordinate(context, operation, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    if scope?(context, operation, parent, child),
      do: exchange(context, operation, {parent, child}, {budget, call, deadline}),
      else: EmbeddedBranchOperation.branch_failure(:identity_conflict, :not_dispatched)
  end

  defp exchange(context, operation, {_parent, child} = records, {budget, call, deadline}) do
    with {:ok, stage} <- control_budget(budget, deadline),
         {:ok, request} <- request(operation, child),
         :ok <-
           EmbeddedBranchOperation.within_budget(
             request,
             stage.max_request_bytes,
             :not_dispatched,
             @frame_overhead
           ) do
      response = call.(context, request, stage)
      reply(context, operation, records, {request, response}, {budget, stage, call, deadline})
    end
  end

  defp reply(context, operation, records, {request, response}, {budget, stage, call, deadline}) do
    if resolution_reply?(context, operation, response, stage) do
      {:ok, outcome, @empty, nil} = response

      case EmbeddedBranchOperation.unused_budget(
             budget,
             request,
             outcome,
             deadline,
             @frame_overhead,
             :not_dispatched
           ) do
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
         {:ok, _} <-
           EmbeddedBranchOperation.branch_remaining(budget, deadline, :dispatch_uncertain),
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
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :not_dispatched)
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
         resolution_supported?(context) and
           EmbeddedBranchOperation.fits?(outcome, budget.max_response_bytes, @frame_overhead) and
           Protocol.valid_outcome?(outcome, 2)

  defp resolution_reply?(_, _, _, _), do: false

  defp control_budget(budget, deadline) do
    with {:ok, budget} <- EmbeddedBranchOperation.branch_remaining(budget, deadline),
         do: Budget.constrain(budget, max_request_bytes: 32 * 1024, max_response_bytes: 96 * 1024)
  end

  defp scope?(context, operation, parent, child),
    do:
      operation in @operations and
        EmbeddedBranchOperation.partial_scope?(context, parent, child, fn ->
          mode?(operation, child)
        end)

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
         :cleanup_partial_branch_disposal,
         child,
         maximum
       ) do
    with :ok <-
           EmbeddedBranchOperation.within_budget(
             outcome,
             maximum,
             :dispatch_uncertain,
             @frame_overhead
           ),
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
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode(
         {:ok, %{"result" => "partial_branch_cleanup_unneeded", "proof" => wire} = outcome,
          @empty, nil},
         :resolve_partial_branch_cleanup,
         child,
         maximum
       ) do
    with :ok <-
           EmbeddedBranchOperation.within_budget(
             outcome,
             maximum,
             :dispatch_uncertain,
             @frame_overhead
           ),
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
           _ -> EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, maximum),
    do: EmbeddedBranchOperation.error_reply(response, :branch, maximum, @frame_overhead)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}

  defp decode(_, _, _, _),
    do: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)

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
        EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
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
      else: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
  end

  defp build_result(source, %PartialBranchDisposalCleanup{} = proof, parent, child) do
    result = %NativePartialBranchCleanupResult{
      version: child.version,
      source: source,
      proof: proof
    }

    if NativePartialBranchCleanupResult.bound?(result, parent, child),
      do: {:ok, result},
      else: EmbeddedBranchOperation.branch_failure(:identity_conflict, :dispatch_uncertain)
  end

  def constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 64 * 1024,
        max_response_bytes: 192 * 1024
      )

  defp now, do: System.monotonic_time(:millisecond)
end
