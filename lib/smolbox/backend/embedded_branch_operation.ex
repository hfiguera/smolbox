defmodule SmolBox.Backend.EmbeddedBranchOperation do
  @moduledoc false
  alias SmolBox.Backend.{Assignment, Budget, EmbeddedContext, EmbeddedReply, Features}
  alias SmolBox.Embedded.{Call, Protocol}
  alias SmolBox.Error

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

  def remaining(budget, deadline, {operation, evidence}, limits \\ []) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout > 0,
      do: Budget.constrain(budget, [timeout_ms: timeout] ++ limits),
      else: failure(:expired, operation, evidence)
  end

  # The Port independently bounds each frame. Debit the aggregate JSON payloads.
  def unused_budget(budget, request, outcome, deadline) do
    input = budget.max_request_bytes - byte_size(Jason.encode!(request))
    output = budget.max_response_bytes - byte_size(Jason.encode!(outcome))

    if input > 0 and output > 0,
      do:
        remaining(
          %{budget | max_request_bytes: input, max_response_bytes: output},
          deadline,
          {:branch, :not_dispatched}
        ),
      else: failure(:output_limit, :branch, :dispatch_uncertain)
  end

  def error_reply({:ok, outcome, @empty, nil} = response, operation, maximum \\ nil) do
    if valid_outcome?(outcome, maximum),
      do: EmbeddedReply.decode(nil, operation, nil, response),
      else: failure(:identity_conflict, operation, :dispatch_uncertain)
  end

  def observation(context, request, {:ok, outcome, @empty, nil} = response, maximum) do
    if valid_outcome?(outcome, maximum),
      do: EmbeddedReply.decode(context, :inspect_machine, request, response),
      else: failure(:identity_conflict, :branch, :dispatch_uncertain)
  end

  def observation(_, _, {:error, %Error{} = error}, _), do: {:error, error}
  def observation(_, _, _, _), do: failure(:identity_conflict, :branch, :dispatch_uncertain)

  defp approved?(_, nil), do: true

  defp approved?(context, child),
    do: Assignment.approved?(child.backend_assignment, context.config, child.spec)

  defp valid_outcome?(outcome, maximum),
    do:
      (is_nil(maximum) or byte_size(Jason.encode!(outcome)) <= maximum) and
        Protocol.valid_outcome?(outcome, 2)

  defp failure(category, operation, evidence),
    do: {:error, %Error{category: category, operation: operation, evidence: evidence}}
end
