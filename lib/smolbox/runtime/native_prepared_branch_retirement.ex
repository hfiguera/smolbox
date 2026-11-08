defmodule SmolBox.Runtime.NativePreparedBranchRetirement do
  @moduledoc false
  alias SmolBox.{Backend, Error, ManagedMachine}
  alias SmolBox.Embedded.NativeBranchAdmission
  alias SmolBox.Embedded.NativePreparedBranchRetirement, as: Retirement
  alias SmolBox.Embedded.NativePreparedBranchRetirementResult
  alias SmolBox.Runtime.{Deadline, MachineSession, NativeResolution, Session, Target}

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
    with true <- NativeBranchAdmission.prepared_child?(child),
         {:ok, parent} <- MachineSession.claim(config, child.branch.source),
         {:ok, worker} <- MachineSession.worker(config, parent),
         :ok <- Target.require_operation(worker, :retire_prepared_branch) do
      deadline = now() + min(Target.connection(worker).budget.timeout_ms, 30_000)

      NativeResolution.run(config, coordinator, parent, worker, :deleted, fn pinned ->
        resolve(config, parent, child, pinned, deadline, fallback)
      end)
    else
      false -> Session.error(:unsupported_capability, :branch)
      error -> error
    end
  end

  defp resolve(config, parent, child, worker, deadline, fallback) do
    with {:ok, timeout} <- Deadline.remaining(deadline, :branch) do
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

  defp commit(config, child, result, deadline),
    do: uncertain(MachineSession.commit_branch_result(config, child, result, deadline))

  defp uncertain(result), do: Error.uncertain(result, :branch)
  defp now, do: System.monotonic_time(:millisecond)
end
