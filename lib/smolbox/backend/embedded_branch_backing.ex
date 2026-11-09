defmodule SmolBox.Backend.EmbeddedBranchBacking do
  @moduledoc false

  alias SmolBox.Backend.{
    Assignment,
    Budget,
    EmbeddedBranchOperation,
    EmbeddedContext,
    Features
  }

  alias SmolBox.Embedded.{
    BranchBackingRelease,
    Call,
    NativeBranchAdmission,
    NativeBranchBacking,
    NativeGrowth,
    Protocol
  }

  alias SmolBox.{Error, ManagedMachine}
  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def run(context, %ManagedMachine{} = parent, %ManagedMachine{} = child, true, budget) do
    {:ok, budget} = constrain(budget)
    deadline = now() + budget.timeout_ms

    with true <-
           EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches),
         true <-
           context.quiesced and
             Assignment.approved?(parent.backend_assignment, context.config, parent.spec) and
             (not NativeBranchBacking.source_scoped?(child) or
                Assignment.approved?(child.backend_assignment, context.config, child.spec)),
         {:ok, pin_budget} <- remaining(budget, deadline, :not_dispatched),
         do:
           coordinate(
             Call.pin(context, pin_budget),
             parent,
             child,
             true,
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

  # Same post-policy sequence for semantic peers. Only the stored accepted intent
  # can reach the accounting mutation; no name-based absence fallback exists.
  def coordinate(context, parent, child, removed, budget, call, deadline \\ nil)

  def coordinate(context, parent, child, true, budget, call, deadline) do
    {:ok, budget} = constrain(budget)
    deadline = deadline || now() + budget.timeout_ms

    with true <-
           context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil,
         true <- scope?(context, parent, child),
         true <- NativeBranchAdmission.backing_pair?(parent, child),
         %NativeBranchBacking{request: request, proof: nil} <-
           child.branch.native_authority.backing,
         {:ok, source, _, _} <- NativeGrowth.head(parent),
         true <- source == request["source"],
         true <- bound?(request, context),
         operation = %{"operation" => operation(child), "request" => request},
         :ok <- input_fits(operation, budget.max_request_bytes),
         {:ok, budget} <- remaining(budget, deadline, :not_dispatched),
         response = call.(context, operation, budget),
         {:ok, _} <- remaining(budget, deadline),
         {:ok, proof} <-
           decode(response, request, context.config.platform, budget.max_response_bytes),
         {:ok, _} <- remaining(budget, deadline),
         do: {:ok, proof},
         else: (
           {:error, %Error{} = error} -> {:error, %{error | operation: :branch}}
           _ -> failure(:identity_conflict, :not_dispatched)
         )
  end

  def coordinate(_, _, _, _, _, _, _), do: failure(:validation, :not_dispatched)

  defp decode(
         {:ok, %{"result" => "branch_backing_released", "proof" => wire} = outcome, @empty, nil},
         request,
         platform,
         maximum
       ) do
    with true <-
           fits?(outcome, maximum) and Protocol.valid_outcome?(outcome, 2) and
             NativeBranchBacking.matches?(wire, request),
         true <- NativeBranchBacking.platform(request) == Atom.to_string(platform),
         {:ok, proof} <- BranchBackingRelease.from_wire(wire),
         do: {:ok, proof},
         else: (_ -> failure(:identity_conflict, :dispatch_uncertain))
  end

  defp decode({:ok, %{"result" => "error"}, @empty, nil} = response, _, _, maximum),
    do: EmbeddedBranchOperation.error_reply(response, :branch, maximum)

  defp decode({:error, %Error{} = error}, _, _, _), do: {:error, error}
  defp decode(_, _, _, _), do: failure(:identity_conflict, :dispatch_uncertain)

  defp remaining(budget, deadline, evidence \\ :dispatch_uncertain),
    do: EmbeddedBranchOperation.remaining(budget, deadline, {:branch, evidence})

  # Unbooted disposal retains source authority. Its original child receipt is
  # immutable evidence, never an operational Machine/Identity to assign.
  defp scope?(context, parent, child) do
    if NativeBranchBacking.source_scoped?(child) do
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.name == parent.machine_name and context.profile == parent.spec.profile and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}
    else
      context.branch_retirement == child and EmbeddedContext.branch_retirement_scope?(context)
    end
  end

  defp bound?(%{"disposal" => disposal} = request, context),
    do:
      get_in(disposal, ~w(publication change child_origin intent epoch)) == context.epoch and
        NativeBranchBacking.platform(request) == Atom.to_string(context.config.platform)

  defp bound?(_, _), do: true

  defp operation(child) do
    cond do
      NativeBranchBacking.partial?(child) -> "release_partial_branch_backing"
      NativeBranchBacking.unbooted?(child) -> "release_unbooted_branch_backing"
      true -> "release_branch_backing"
    end
  end

  defp input_fits(value, maximum),
    do: if(fits?(value, maximum), do: :ok, else: failure(:output_limit, :not_dispatched))

  defp fits?(value, maximum), do: byte_size(Jason.encode!(value)) <= maximum

  defp constrain(budget),
    do:
      Budget.constrain(budget,
        timeout_ms: 30_000,
        max_request_bytes: 84 * 1024,
        max_response_bytes: 72 * 1024
      )

  defp failure(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}

  defp now, do: System.monotonic_time(:millisecond)
end
