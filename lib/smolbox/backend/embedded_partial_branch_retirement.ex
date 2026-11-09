defmodule SmolBox.Backend.EmbeddedPartialBranchRetirement do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Budget, EmbeddedContext, EmbeddedReply, Features}

  alias SmolBox.Embedded.{
    Call,
    NativeBranchAdmission,
    NativeBranchRetirement,
    NativeGrowth,
    PartialBranchChildAbsence,
    PartialBranchDisposal,
    Protocol
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(context, %ManagedMachine{} = parent, %ManagedMachine{} = child, budget) do
    {:ok, budget} = constrain(budget)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(child.backend_assignment, context.config, child.spec),
         {:ok, pin_budget} <- remaining(budget, deadline, :not_dispatched),
         do:
           coordinate(Call.pin(context, pin_budget), parent, child, budget, &Call.run/3, deadline),
         else: (
           {:error, _} = error -> error
           _ -> failure(:unsupported_capability, :not_dispatched)
         )
  end

  def run(_, _, _, _), do: failure(:validation, :not_dispatched)

  # Original source scope is required. The disposed child has no Machine or
  # boot-completion receipt to assign or adopt as an operational identity.
  def coordinate(context, parent, child, budget, call, deadline \\ nil) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <- scope?(context, parent, child),
         {:ok, request} <- NativeBranchRetirement.request(child),
         operation = %{
           "operation" => "qualify_partial_branch_child_absence",
           "request" => request
         },
         :ok <- input_fits(operation, budget.max_request_bytes),
         true <- bound?(request, context),
         {:ok, transfer_budget} <- remaining(budget, deadline, :not_dispatched),
         response = call.(context, operation, transfer_budget),
         {:ok, proof} <- decode(response, request, budget.max_response_bytes),
         {:ok, _} <- remaining(budget, deadline),
         do: {:ok, proof},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  defp scope?(context, parent, child),
    do:
      pinned?(context) and NativeBranchAdmission.retirement_pair?(parent, child) and
        match?(
          %{partial_disposal: %{proof: %PartialBranchDisposal{}}},
          child.branch.native_authority
        ) and
        source_context?(context, parent)

  defp pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  defp source_context?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.name == parent.machine_name and context.profile == parent.spec.profile and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  defp bound?(request, context),
    do:
      PartialBranchChildAbsence.epoch(request) == context.epoch and
        PartialBranchChildAbsence.platform(request) == Atom.to_string(context.config.platform)

  defp decode(
         {:ok, %{"result" => "partial_branch_child_absent", "proof" => wire} = outcome, @empty,
          nil},
         request,
         maximum
       ) do
    with true <- fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
         true <- PartialBranchChildAbsence.matches?(wire, request),
         {:ok, proof} <- PartialBranchChildAbsence.from_wire(wire),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"} = outcome, @empty, nil} = response, _, maximum) do
    if fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2),
      do: EmbeddedReply.decode(nil, :branch, nil, response),
      else: failure(:identity_conflict, :dispatch_uncertain)
  end

  defp decode({:error, %Error{} = error}, _, _), do: {:error, error}
  defp decode(_, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp input_fits(value, maximum),
    do: if(fits?(value, maximum), do: :ok, else: failure(:output_limit, :not_dispatched))

  defp fits?(value, maximum), do: byte_size(Jason.encode!(value)) <= maximum

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 60 * 1024,
        max_response_bytes: 60 * 1024
      )

  defp remaining(budget, deadline, evidence \\ :dispatch_uncertain) do
    timeout = deadline - now()

    if timeout > 0,
      do: constrain(%{budget | timeout_ms: min(timeout, budget.timeout_ms)}),
      else: failure(:expired, evidence)
  end

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
