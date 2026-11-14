defmodule SmolBox.Kubernetes.RecordValidation do
  @moduledoc false
  alias SmolBox.Kubernetes.{Assignment, CleanupProof, ExecutionPolicy, Identity, Receipt}

  def valid?(assignment, record),
    do:
      Assignment.record_matches?(assignment, record) and
        ExecutionPolicy.supported?(record.spec) and
        record.backend_create_state in [:pending, :dispatched] and
        receipt?(record.backend_receipt, assignment, record) and
        stage?(record) and
        owned?(record.created_machine, assignment, record.backend_receipt)

  def releasable?(
        %{backend_assignment: %Assignment{}, backend_cleanup: :not_dispatched} = record
      ),
      do: record.backend_create_state == :pending and record.backend_receipt == nil

  def releasable?(%{backend_assignment: %Assignment{}} = record),
    do: CleanupProof.releasable?(record.backend_cleanup, record.backend_receipt)

  def releasable?(_record), do: true

  def fields?(record) do
    if ExecutionPolicy.required?(record),
      do: disposable?(record) and cleanup?(record),
      else: empty?(record)
  end

  def transition?(previous, next),
    do:
      create_transition?(previous.backend_create_state, next.backend_create_state) and
        receipt_transition?(previous.backend_receipt, next.backend_receipt) and
        previous.backend_cleanup in [nil, next.backend_cleanup] and
        (previous.backend_cleanup == nil or previous.backend_receipt == next.backend_receipt)

  defp empty?(record),
    do:
      record.backend_receipt == nil and record.backend_cleanup == nil and
        record.backend_create_state == nil

  defp disposable?(%{backend_assignment: nil} = record),
    do:
      ExecutionPolicy.supported?(record.spec) and record.managed_machine == nil and
        record.worker_id == nil and record.created_machine == nil and empty?(record)

  defp disposable?(%{backend_assignment: %Assignment{}}), do: true
  defp disposable?(_), do: false

  defp cleanup?(%{backend_assignment: nil}), do: true

  defp cleanup?(%{backend_cleanup: nil, cleanup: status}), do: status != :complete

  defp cleanup?(%{backend_create_state: :pending, backend_receipt: nil} = record),
    do: record.backend_cleanup == :not_dispatched and record.cleanup == :complete

  defp cleanup?(%{backend_create_state: :dispatched} = record),
    do:
      CleanupProof.matches?(record.backend_cleanup, record.backend_receipt) and
        record.cleanup == :complete and
        record.absence_at_ms == record.backend_cleanup.observed_at_ms

  defp cleanup?(_), do: false

  defp receipt?(nil, _assignment, record), do: record.created_machine == nil

  defp receipt?(receipt, assignment, record),
    do:
      record.backend_create_state == :dispatched and
        Receipt.matches_assignment?(receipt, assignment)

  defp stage?(%{state: state} = record)
       when state in [
              :ready,
              :dispatching,
              :running,
              :collecting,
              :completed,
              :collection_failed,
              :cancelling
            ],
       do:
         match?(%Receipt{phase: :ready}, record.backend_receipt) and record.created_machine != nil

  defp stage?(_record), do: true

  defp owned?(nil, _assignment, _receipt), do: true

  defp owned?(%{__struct__: SmolBox.Machine, backend_identity: identity}, assignment, receipt),
    do:
      Identity.matches?(identity, assignment) and identity.receipt.phase == :ready and
        Receipt.same_incarnation?(identity.receipt, receipt)

  defp owned?(_machine, _assignment, _receipt), do: false

  defp create_transition?(state, state), do: true
  defp create_transition?(:pending, :dispatched), do: true
  defp create_transition?(_, _), do: false

  defp receipt_transition?(receipt, receipt), do: true
  defp receipt_transition?(nil, %Receipt{phase: :created} = receipt), do: Receipt.valid?(receipt)

  defp receipt_transition?(%Receipt{phase: :created} = old, %Receipt{} = next),
    do: Receipt.same_creation?(old, next)

  defp receipt_transition?(%Receipt{phase: :ready} = old, %Receipt{phase: :ready} = next),
    do:
      Receipt.same_incarnation?(old, next) and
        next.observation.observed_at_ms >= old.observation.observed_at_ms

  defp receipt_transition?(_, _), do: false
end
