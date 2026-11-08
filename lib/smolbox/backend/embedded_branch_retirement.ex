defmodule SmolBox.Backend.EmbeddedBranchRetirement do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    BranchChildAbsence,
    Call,
    NativeBranchRetirement,
    Protocol
  }

  alias SmolBox.Error
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(context, name, budget) do
    {:ok, budget} = Budget.constrain(budget, timeout_ms: 30_000, max_response_bytes: 72 * 1024)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <- context.quiesced,
         {:ok, pin_budget} <- remaining(budget, deadline),
         do: coordinate(Call.pin(context, pin_budget), name, budget, &Call.run/3, deadline),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  # Shared semantic sequence after production policy and owner-fence admission.
  # It never turns an SDK inventory/absence atom into dependency retirement.
  def coordinate(context, name, budget, call, deadline \\ nil) do
    deadline = deadline || now() + min(budget.timeout_ms, 30_000)

    with true <-
           context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil,
         true <- name == context.name and EmbeddedContext.branch_retirement_scope?(context),
         {:ok, request} <- NativeBranchRetirement.request(context.branch_retirement),
         operation = %{"operation" => "qualify_branch_child_absence", "request" => request},
         {:ok, budget} <- remaining(budget, deadline),
         response = call.(context, operation, budget),
         {:ok, _} <- remaining(budget, deadline),
         {:ok, proof} <- decode(response, request, context.config.platform),
         {:ok, _} <- remaining(budget, deadline),
         do: {:ok, proof},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :dispatch_uncertain)
         )
  end

  defp decode(
         {:ok, %{"result" => "branch_child_absent", "proof" => wire} = outcome, @empty, nil},
         request,
         platform
       ) do
    with true <-
           Protocol.valid_outcome?(outcome, 2) and BranchChildAbsence.matches?(wire, request),
         true <- BranchChildAbsence.platform(request) == Atom.to_string(platform),
         {:ok, proof} <- BranchChildAbsence.from_wire(wire),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, _) do
    if Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _), do: {:error, error}
  defp decode(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp remaining(budget, deadline) do
    timeout = deadline - now()

    if timeout > 0,
      do: Budget.constrain(budget, timeout_ms: timeout, max_response_bytes: 72 * 1024),
      else: failure(:expired, :dispatch_uncertain)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
