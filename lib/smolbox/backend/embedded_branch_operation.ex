defmodule SmolBox.Backend.EmbeddedBranchOperation do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Budget, EmbeddedContext, EmbeddedReply, Features}
  alias SmolBox.Embedded.{Call, NativeBranchAdmission, NativeGrowth, Protocol}
  alias SmolBox.{Error, ManagedMachine}

  @empty %{stdout: <<>>, stderr: <<>>, file: <<>>}

  def pin(context, budget, deadline, {operation, _} = expiry, child \\ nil) do
    if EmbeddedContext.scoped?(context) and Features.supports?(context.config, :branches) and
         context.quiesced and approved?(context, child) do
      with {:ok, pin_budget} <- remaining(budget, deadline, expiry),
           do: {:ok, Call.pin(context, pin_budget)}
    else
      failure(:unsupported_capability, operation, :not_dispatched)
    end
  end

  def run_disposal(
        context,
        operation,
        [%ManagedMachine{} = parent, %ManagedMachine{} = child],
        budget,
        module
      ) do
    {:ok, budget} = module.constrain(budget)
    deadline = System.monotonic_time(:millisecond) + budget.timeout_ms

    with {:ok, pinned} <- pin(context, budget, deadline, {:branch, :not_dispatched}, child),
         do: module.coordinate(pinned, operation, parent, child, budget, &Call.run/3, deadline)
  end

  def run_disposal(_, _, _, _, _), do: branch_failure(:validation, :not_dispatched)

  def branch_remaining(budget, deadline, evidence \\ :not_dispatched),
    do: remaining(budget, deadline, {:branch, evidence})

  def branch_failure(category, evidence), do: failure(category, :branch, evidence)

  def remaining(budget, deadline, {operation, evidence}, limits \\ []) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: Budget.constrain(budget, [timeout_ms: timeout] ++ limits),
      else: failure(:expired, operation, evidence)
  end

  def pinned?(context),
    do: context.pinned and context.quiesced and is_pid(context.server) and context.epoch != nil

  def source?(context, parent),
    do:
      context.spec == parent.spec and context.assignment == parent.backend_assignment and
        context.profile == parent.spec.profile and context.name == parent.machine_name and
        NativeGrowth.current_identity(parent) == {:ok, context.identity}

  def partial_scope?(context, parent, child, eligible?) do
    with true <- pinned?(context),
         true <- NativeBranchAdmission.partial_disposal_pending?(parent, child),
         true <- source?(context, parent),
         true <- eligible?.(),
         %{platform: platform} <- child.branch.native_authority.partial_disposal,
         do: platform == platform(context),
         else: (_ -> false)
  end

  def platform(context), do: Atom.to_string(context.config.platform)

  def wire_size(value, overhead), do: byte_size(Jason.encode!(value)) + overhead

  def fits?(value, maximum, overhead), do: wire_size(value, overhead) <= maximum

  def within_budget(value, limit, evidence, overhead),
    do:
      if(fits?(value, limit, overhead), do: :ok, else: failure(:output_limit, :branch, evidence))

  # The Port independently bounds each frame. Debit the aggregate JSON payloads.
  def unused_budget(
        budget,
        request,
        outcome,
        deadline,
        overhead \\ 0,
        evidence \\ :dispatch_uncertain
      ) do
    input = budget.max_request_bytes - wire_size(request, overhead)
    output = budget.max_response_bytes - wire_size(outcome, overhead)

    if input > 0 and output > 0,
      do:
        remaining(
          %{budget | max_request_bytes: input, max_response_bytes: output},
          deadline,
          {:branch, :not_dispatched}
        ),
      else: failure(:output_limit, :branch, evidence)
  end

  def error_reply(
        {:ok, outcome, @empty, nil} = response,
        operation,
        maximum \\ nil,
        overhead \\ 0
      ) do
    if valid_outcome?(outcome, maximum, overhead),
      do: EmbeddedReply.decode(nil, operation, nil, response),
      else: failure(:identity_conflict, operation, :dispatch_uncertain)
  end

  def observation(context, request, response, maximum, overhead \\ 0)

  def observation(context, request, {:ok, outcome, @empty, nil} = response, maximum, overhead) do
    if valid_outcome?(outcome, maximum, overhead),
      do: EmbeddedReply.decode(context, :inspect_machine, request, response),
      else: failure(:identity_conflict, :branch, :dispatch_uncertain)
  end

  def observation(_, _, {:error, %Error{} = error}, _, _), do: {:error, error}
  def observation(_, _, _, _, _), do: failure(:identity_conflict, :branch, :dispatch_uncertain)

  defp approved?(_, nil), do: true

  defp approved?(context, child),
    do: Assignment.approved?(child.backend_assignment, context.config, child.spec)

  defp valid_outcome?(outcome, maximum, overhead),
    do:
      (is_nil(maximum) or wire_size(outcome, overhead) <= maximum) and
        Protocol.valid_outcome?(outcome, 2)

  defp failure(category, operation, evidence),
    do: {:error, %Error{category: category, operation: operation, evidence: evidence}}
end
