defmodule SmolBox.Runtime.NativePreparedBranchRetirement do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.NativePreparedBranchRetirement, as: Retirement
  alias SmolBox.Embedded.NativePreparedBranchRetirementResult
  alias SmolBox.Runtime.{MachineSession, NativeResolution, Session, Target}

  def run(config, coordinator, child), do: run(config, coordinator, child, nil)

  # An existing immutable acknowledgement needs no live helper or namespace IO.
  def run(
        _config,
        _coordinator,
        %{branch: %{native_authority: %{prepared_retirement: %Retirement{}}}} = child,
        _fallback
      ) do
    if ManagedMachine.validate(child) == :ok,
      do: {:ok, child},
      else: Session.error(:identity_conflict, :branch)
  end

  def run(config, coordinator, child, fallback) do
    with true <- Retirement.eligible?(child),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- Target.require_operation(worker, :retire_prepared_branch) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(
        config,
        coordinator,
        parent,
        worker,
        :deleted,
        fn pinned ->
          resolve(config, parent, child, pinned, deadline, fallback)
        end,
        deadline
      )
    else
      false -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp resolve(config, parent, child, worker, deadline, fallback) do
    with {:ok, timeout} <- remaining(deadline) do
      case observe(config, parent, child, worker, timeout) do
        {:ok, result} ->
          commit(config, child, result, deadline)

        {:error, _} = error when is_function(fallback, 5) ->
          fallback.(parent, child, worker, deadline, error)

        error ->
          error
      end
    end
  end

  defp observe(config, parent, child, worker, timeout) do
    reference =
      worker
      |> Target.connection(parent)
      |> Backend.bounded(
        timeout_ms: timeout,
        max_request_bytes: 32 * 1024,
        max_response_bytes: 32 * 1024
      )

    io_record = %{parent | operation_deadline_ms: config.clock.now() + timeout}

    case MachineSession.io(config, io_record, fn ->
           {:native_response, Backend.retire_prepared_branch(reference, parent, child)}
         end) do
      {:native_response, {:ok, %NativePreparedBranchRetirementResult{} = result}} ->
        if NativePreparedBranchRetirementResult.bound?(result, parent, child),
          do: {:ok, result},
          else: uncertain(Session.error(:identity_conflict, :branch))

      {:native_response, {:error, %Error{}} = error} ->
        error

      {:error, %Error{}} = error ->
        uncertain(error)

      _ ->
        uncertain(Session.error(:unknown, :branch))
    end
  end

  defp commit(config, child, result, deadline) do
    result =
      with {:ok, _} <- remaining(deadline),
           {:ok, current} <- MachineSession.claim(config, child.branch.source),
           {:ok, _} <- remaining(deadline),
           do:
             MachineSession.store(config, :branch_resolve, [
               child.branch.source,
               Session.guard(current),
               child.id,
               result.source,
               result,
               config.clock.now()
             ])

    uncertain(result)
  end

  defp remaining(deadline) do
    timeout = deadline - now()
    if timeout > 0, do: {:ok, timeout}, else: Session.error(:expired, :branch)
  end

  defp uncertain({:error, %Error{} = error}),
    do: {:error, %{error | operation: :branch, evidence: :dispatch_uncertain}}

  defp uncertain(result), do: result
  defp now, do: System.monotonic_time(:millisecond)
end
