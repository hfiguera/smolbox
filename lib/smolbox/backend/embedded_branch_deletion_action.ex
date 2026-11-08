defmodule SmolBox.Backend.EmbeddedBranchDeletionAction do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedBranchOperation, EmbeddedContext, Features}

  alias SmolBox.Embedded.{
    BranchDeletionCollection,
    BranchDeletionContinuation,
    BranchDeletionResolution,
    Call,
    NativeBranchDeletionAction,
    NativeBranchDeletionCollection,
    NativeReleasedBranchDeletionCleanup,
    NativeReleasedBranchDeletionContinuation,
    Protocol,
    ReleasedBranchDeletionContinuation,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(%EmbeddedContext{} = context, %ManagedMachine{} = child, action, budget)
      when action in [:collect, :continue, :cleanup] do
    with {:ok, budget} <- Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 8192),
         true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <- context.quiesced do
      deadline = now() + budget.timeout_ms
      coordinate(Call.pin(context, budget), child, action, budget, &Call.run/3, deadline)
    else
      {:error, _} = error -> error
      _ -> failure(:unsupported_capability, :not_dispatched)
    end
  end

  def run(_, _, _, _), do: failure(:validation, :not_dispatched)

  def coordinate(context, child, action, budget, call, deadline \\ nil)

  def coordinate(%EmbeddedContext{} = context, child, action, budget, call, deadline)
      when action in [:collect, :continue, :cleanup] do
    deadline = deadline || now() + min(budget.timeout_ms, 30_000)

    with true <-
           context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil,
         true <-
           EmbeddedContext.branch_deletion_scope?(context) and context.branch_deletion == child,
         true <- NativeBranchDeletionAction.eligible?(child, action),
         saved =
           Map.fetch!(child.branch.native_authority, NativeBranchDeletionAction.field(action)),
         {:ok, name, kind, reader, request} <- exchange(saved, action),
         true <-
           get_in(request, ~w(completion publication change platform)) ==
             Atom.to_string(context.config.platform),
         {:ok, budget} <- remaining(budget, deadline, :not_dispatched) do
      operation = %{"operation" => name, "request" => request}
      response = call.(context, operation, budget)

      with {:ok, _} <- remaining(budget, deadline, :dispatch_uncertain),
           {:ok, proof} <- decode(response, saved, action, {kind, reader}),
           {:ok, _} <- remaining(budget, deadline, :dispatch_uncertain),
           do: {:ok, proof}
    else
      {:error, %Error{} = error} -> {:error, %{error | operation: :reconcile}}
      _ -> failure(:identity_conflict, :not_dispatched)
    end
  end

  def coordinate(_, _, _, _, _, _), do: failure(:validation, :not_dispatched)

  defp exchange(%NativeBranchDeletionCollection{request: request, proof: nil}, :collect),
    do:
      {:ok, "collect_branch_deletion", "branch_deletion_collected", BranchDeletionCollection,
       request}

  defp exchange(%NativeBranchDeletionAction{request: request, proof: nil}, action),
    do: {:ok, "#{action}_held_branch_deletion", result(action), proof_module(action), request}

  defp exchange(
         %NativeReleasedBranchDeletionContinuation{request: request, proof: nil},
         :continue
       ),
       do:
         {:ok, "continue_released_branch_deletion", "released_branch_deletion_continued",
          ReleasedBranchDeletionContinuation, request}

  defp exchange(
         %NativeReleasedBranchDeletionCleanup{request: request, proof: nil},
         :cleanup
       ),
       do:
         {:ok, "cleanup_released_branch_deletion", "released_branch_deletion_cleaned",
          ReleasedBranchDeletionResolution, request}

  defp exchange(_, _), do: :error

  defp decode(
         {:ok, %{"result" => kind, "proof" => wire} = outcome, @empty, nil},
         saved,
         action,
         {expected, reader}
       ) do
    with true <- kind == expected and Protocol.valid_outcome?(outcome, 2),
         {:ok, proof} <- reader.from_wire(wire),
         true <- NativeBranchDeletionAction.matches?(saved, action, proof),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, _),
    do: EmbeddedBranchOperation.error_reply(response, :reconcile)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, %{error | operation: :reconcile}}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp result(:continue), do: "held_branch_deletion_continued"
  defp result(:cleanup), do: "held_branch_deletion_cleaned"
  defp proof_module(:continue), do: BranchDeletionContinuation
  defp proof_module(:cleanup), do: BranchDeletionResolution

  defp remaining(budget, deadline, evidence) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout, max_response_bytes: 8192),
      else: failure(:expired, evidence)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :reconcile, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
