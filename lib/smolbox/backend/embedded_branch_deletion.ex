defmodule SmolBox.Backend.EmbeddedBranchDeletion do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedBranchOperation, EmbeddedContext}

  alias SmolBox.Embedded.{
    BranchDeletionResolution,
    Call,
    NativeBranchDeletion,
    NativeReleasedBranchDeletion,
    Protocol,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}
  @response_bytes 8192

  def run(context, %ManagedMachine{} = child, budget) do
    {:ok, budget} =
      Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: @response_bytes)

    deadline = now() + budget.timeout_ms

    with {:ok, pinned} <-
           EmbeddedBranchOperation.pin(
             context,
             budget,
             deadline,
             {:reconcile, :dispatch_uncertain}
           ),
         do: coordinate(pinned, child, budget, &Call.run/3, deadline)
  end

  def run(_, _, _), do: failure(:validation, :not_dispatched)

  def coordinate(context, child, budget, call, deadline \\ nil) do
    deadline = deadline || now() + min(budget.timeout_ms, 30_000)

    with true <-
           context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil,
         true <-
           EmbeddedContext.branch_deletion_scope?(context) and context.branch_deletion == child,
         {:ok, name, reader, request} <- exchange(child.branch.native_authority.deletion),
         operation = %{"operation" => name, "request" => request},
         {:ok, budget} <- remaining(budget, deadline),
         response = call.(context, operation, budget),
         {:ok, _} <- remaining(budget, deadline),
         {:ok, proof} <- decode(response, request, context.config.platform, reader),
         {:ok, _} <- remaining(budget, deadline),
         do: {:ok, proof},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :reconcile}}
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp exchange(%NativeBranchDeletion{request: request, proof: nil}),
    do: {:ok, "resolve_held_branch_deletion", BranchDeletionResolution, request}

  defp exchange(%NativeReleasedBranchDeletion{request: request, proof: nil}),
    do: {:ok, "resolve_released_branch_deletion", ReleasedBranchDeletionResolution, request}

  defp exchange(_), do: :error
  defp result(BranchDeletionResolution), do: "held_branch_deletion_resolved"
  defp result(ReleasedBranchDeletionResolution), do: "released_branch_deletion_resolved"

  defp decode(
         {:ok, %{"result" => kind, "proof" => wire} = outcome, @empty, nil},
         request,
         platform,
         reader
       ) do
    with true <-
           kind == result(reader) and Protocol.valid_outcome?(outcome, 2) and
             reader.matches?(wire, request),
         true <- reader.platform(request) == Atom.to_string(platform),
         {:ok, proof} <- reader.from_wire(wire),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, _),
    do: EmbeddedBranchOperation.error_reply(response, :reconcile)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp remaining(budget, deadline),
    do:
      EmbeddedBranchOperation.remaining(budget, deadline, {:reconcile, :dispatch_uncertain},
        max_response_bytes: @response_bytes
      )

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :reconcile, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
