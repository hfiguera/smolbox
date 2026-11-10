defmodule SmolBox.Store.NativeBranchReleaseOps do
  @moduledoc false
  alias SmolBox.Embedded.{NativeBranchRelease, NativeBranchReleaseResult, NativeGrowth}

  alias SmolBox.{BranchReleaseEnv, DiskExpansion, Error, Machine, ManagedMachine, Validation}

  def accept(parent, child, version, now), do: accept(parent, child, version, [], now)

  def accept(parent, child, version, env, now) do
    cond do
      not (Validation.integer?(version, 1, 9_007_199_254_740_991) and
             Validation.timestamp?(now) and BranchReleaseEnv.valid?(env)) ->
        error(:validation)

      child.branch.release_version == version ->
        if child.branch.release_env == env,
          do: {:ok, parent, child},
          else: error(:identity_conflict)

      child.version != version ->
        error(:stale_version)

      true ->
        insert(parent, child, version, env, now)
    end
  end

  defp insert(parent, child, version, env, now) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- related?(parent, child) and parent.state == :running and child.state == :running,
         true <- ManagedMachine.idle?(parent) and ManagedMachine.idle?(child),
         true <- child.branch.state == :held and child.branch.native_authority.release == nil,
         true <-
           parent.observed_machine.backend_identity.pid_identity ==
             child.branch.source_machine.backend_identity.pid_identity,
         {:ok, receipt, _, _} <- NativeGrowth.head(parent),
         true <-
           receipt == parent.observed_machine.backend_identity.receipt and
             Machine.same_incarnation?(DiskExpansion.expected(parent), parent.observed_machine),
         release = NativeBranchRelease.new(parent, child, version, env),
         authority = %{child.branch.native_authority | release: release},
         deadline = now + child.branch.spec.timeout_ms,
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               active_branch: child.id,
               operation: :branch,
               phase: :pending,
               operation_deadline_ms: deadline,
               next_due_at_ms: now
             },
             now
           ),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: :release_pending,
                   release_version: version,
                   release_env: env,
                   deadline_ms: deadline,
                   native_authority: authority
               },
               operation: :branch_release,
               phase: :pending,
               operation_deadline_ms: deadline,
               next_due_at_ms: now
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error(:admission_exhausted))
  end

  def advance(parent, child, expected, action, now) do
    with true <- Validation.timestamp?(now),
         :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- related?(parent, child) and parent.active_branch == child.id,
         true <- child.branch.state == expected and child.operation == :branch_release,
         do: step(parent, child, action, now),
         else: (_ -> error(:stale_version))
  end

  defp step(parent, %{branch: %{state: :release_pending}} = child, :dispatching, now) do
    with true <- now <= child.branch.deadline_ms,
         {:ok, parent} <- ManagedMachine.update(parent, %{phase: :dispatching}, now),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{branch: %{child.branch | state: :release_dispatching}, phase: :dispatching},
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error(:expired))
  end

  defp step(parent, child, :unknown, now)
       when child.branch.state in [:release_pending, :release_dispatching] do
    with {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{state: :unknown, phase: :uncertain, next_due_at_ms: now + 60_000},
             now
           ),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{child.branch | state: :unknown},
               state: :unknown,
               phase: :uncertain,
               last_error: %Error{category: :unknown, operation: :branch, evidence: :unknown},
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child}
  end

  defp step(
         parent,
         %{branch: %{state: :release_dispatching}} = child,
         {:native_complete, result},
         now
       ) do
    if Validation.timestamp?(now) and now <= child.branch.deadline_ms,
      do: commit(parent, child, result, now),
      else: error(:expired)
  end

  defp step(_, _, _, _), do: error(:identity_conflict)

  def resolve(parent, child, result, now) do
    with true <- Validation.timestamp?(now) and child.branch.state == :unknown,
         :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <-
           related?(parent, child) and parent.active_branch == child.id and
             child.operation == :branch_release,
         do: commit(parent, child, result, now),
         else: (_ -> error(:identity_conflict))
  end

  defp commit(parent, child, %NativeBranchReleaseResult{} = result, now) do
    authority = child.branch.native_authority

    with true <- NativeBranchReleaseResult.bound?(result, authority),
         {:ok, receipt, _, _} <- NativeGrowth.head(parent),
         true <- receipt == authority.release.source,
         authority = %{authority | release: %{authority.release | transition: result.transition}},
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               state: :running,
               observed_machine: result.source,
               active_branch: nil,
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               last_error: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               state: :running,
               observed_machine: result.child,
               branch: %{child.branch | state: :released, native_authority: authority},
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               last_error: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error(:identity_conflict))
  end

  defp commit(_, _, _, _), do: error(:identity_conflict)

  defp related?(parent, child),
    do:
      child.branch.source == ManagedMachine.key(parent) and
        parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        parent.branch_children[child.id] == false

  defp error(category), do: {:error, %Error{category: category, operation: :branch}}
end
