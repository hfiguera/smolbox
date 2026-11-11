defmodule SmolBox.Store.NativeBranchOps do
  @moduledoc false
  alias SmolBox.Backend.Assignment

  alias SmolBox.Embedded.{
    BranchPublication,
    NativeBranchAuthority,
    NativeBranchResult,
    NativeCollectedBranchPublication,
    NativeGrowth
  }

  alias SmolBox.Store.RecordOps

  alias SmolBox.{
    Branch,
    BranchSpec,
    DiskExpansion,
    Error,
    Machine,
    ManagedMachine,
    Profile,
    Validation
  }

  def accept(parent, spec, fingerprint, name, capacity, usage, now) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- BranchSpec.validate(spec),
         true <- Validation.digest?(fingerprint) and SmolBox.MachineSpec.valid_name?(name),
         true <- parent.state == :running and ManagedMachine.idle?(parent),
         true <- parent.branch == nil and parent.id != spec.id,
         true <- source_mode?(parent.spec, spec.hold),
         true <-
           parent.spec.ports == [] and parent.spec.volumes == [] and parent.spec.workload == nil,
         true <-
           map_size(parent.branch_children) < 256 and
             not Map.has_key?(parent.branch_children, spec.id),
         {:ok, receipt, _, _} <- NativeGrowth.head(parent),
         true <- parent.observed_machine.backend_identity.receipt == receipt,
         true <-
           Machine.same_incarnation?(DiskExpansion.expected(parent), parent.observed_machine),
         true <- unused?(parent, spec.id),
         profile = DiskExpansion.profile(parent),
         true <- capacity?(profile, spec.policy.resources, capacity, usage),
         {:ok, authority} <-
           NativeBranchAuthority.new(parent, spec, fingerprint, name, profile),
         {:ok, child} <-
           ManagedMachine.new(
             %{parent.spec | id: spec.id, profile: profile, checkpointable: false},
             fingerprint,
             now
           ),
         branch = %Branch{
           source: ManagedMachine.key(parent),
           source_machine: parent.observed_machine,
           spec: spec,
           accepted_at_ms: now,
           deadline_ms: now + spec.timeout_ms,
           native_authority: authority
         },
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: branch,
               backend_assignment:
                 struct!(
                   Assignment,
                   NativeBranchAuthority.assignment_fields(
                     authority,
                     child.spec.artifact,
                     profile
                   )
                 ),
               worker_id: parent.worker_id,
               worker_generation: parent.worker_generation,
               machine_name: name,
               reservation: RecordOps.resources(child),
               state: :creating,
               operation: :branch_child,
               phase: :pending,
               operation_deadline_ms: branch.deadline_ms
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               branch_children: Map.put(parent.branch_children, spec.id, false),
               active_branch: spec.id,
               operation: :branch,
               phase: :pending,
               operation_deadline_ms: branch.deadline_ms,
               next_due_at_ms: now
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp source_mode?(spec, hold),
    do:
      (spec.checkpointable and spec.profile.network == :offline) or
        (spec.branch_static_egress and hold)

  defp unused?(parent, id) do
    not Map.has_key?(parent.native_branch_history, id) and
      case NativeGrowth.transitions(parent) do
        {:ok, history} -> Enum.all?(history, &(&1.receipt["material"]["operation_id"] != id))
        _ -> false
      end
  end

  def complete(parent, child, result, now), do: commit(parent, child, result, :dispatching, now)
  def resolve(parent, child, result, now), do: commit(parent, child, result, :unknown, now)

  defp commit(parent, child, %NativeBranchResult{} = result, expected, now) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- child.branch.state == expected and parent.active_branch == child.id,
         true <- completion_pending?(parent, child),
         true <- within_budget?(child, expected, now),
         true <- NativeBranchResult.bound?(result, parent, child),
         {:ok, proof} <- BranchPublication.from_wire(result.completion.publication),
         true <- NativeCollectedBranchPublication.publication_pending?(parent, child, proof),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               native_branch_history: Map.put(parent.native_branch_history, child.id, proof),
               active_branch: nil,
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               state: :running,
               observed_machine: result.source,
               last_error: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         authority = %{child.branch.native_authority | completion: result.completion},
         root = %{
           result.child
           | state: :created,
             backend_identity: NativeBranchAuthority.root(authority)
         },
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{
                 child.branch
                 | state: if(result.completion.held, do: :held, else: :ready),
                   native_authority: authority
               },
               created_machine: root,
               observed_machine: result.child,
               state: :running,
               operation: nil,
               phase: nil,
               last_error: nil,
               operation_deadline_ms: nil,
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error(:identity_conflict))
  end

  defp commit(_, _, _, _, _), do: error(:identity_conflict)

  defp completion_pending?(parent, child),
    do:
      parent.operation == :branch and child.operation == :branch_child and
        child.branch.native_authority.completion == nil and
        parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        parent.branch_children[child.id] == false

  defp within_budget?(child, :dispatching, now),
    do: Validation.timestamp?(now) and now <= child.branch.deadline_ms

  defp within_budget?(_child, :unknown, now), do: Validation.timestamp?(now)

  def cancel(parent, child, action, now) do
    with true <- child.branch.state == :accepted and action in [:failed, :cancelled],
         {:ok, receipt, _, _} <- NativeGrowth.head(parent),
         true <- receipt == child.branch.native_authority.request["source"],
         {:ok, child} <-
           ManagedMachine.update(
             child,
             %{
               branch: %{child.branch | state: action},
               state: :deleted,
               reservation: nil,
               operation: nil,
               phase: nil,
               last_error: nil,
               absence_at_ms: child.absence_at_ms || now,
               operation_deadline_ms: nil
             },
             now
           ),
         {:ok, parent} <-
           ManagedMachine.update(
             parent,
             %{
               active_branch: nil,
               operation: nil,
               phase: nil,
               operation_deadline_ms: nil,
               branch_children: Map.put(parent.branch_children, child.id, true),
               next_due_at_ms: now + 60_000
             },
             now
           ),
         do: {:ok, parent, child},
         else: (_ -> error())
  end

  defp capacity?(profile, extra, capacity, usage) do
    child = Profile.resources(profile)
    needed = Map.merge(child, extra, fn _, a, b -> a + b end)

    extra.memory_mb >= child.memory_mb and
      extra.disk_gb >= 2 * child.disk_gb + div(profile.memory_mb + 1023, 1024) and
      is_map(capacity) and Enum.sort(Map.keys(capacity)) == Enum.sort(Map.keys(needed)) and
      Enum.all?(needed, fn {key, value} ->
        is_integer(capacity[key]) and is_integer(usage[key]) and
          usage[key] + value <= capacity[key]
      end)
  end

  defp error(category \\ :admission_exhausted),
    do: {:error, %Error{category: category, operation: :branch}}
end
