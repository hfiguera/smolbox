defmodule SmolBox.Runtime.KubernetesInspection do
  @moduledoc false
  alias SmolBox.{Error, Execution}
  alias SmolBox.Kubernetes.{Assignment, Operation, Pod, PodTemplate}
  alias SmolBox.Runtime.Session
  alias SmolBox.Store.BackendAssignments

  # API observations describe ownership, never physical absence or release.
  # One authenticated assignment per page keeps durable reads bounded, including
  # unresolved records whose original API object has already disappeared.
  def page(config, target, options) do
    cursor = Keyword.get(options, :cursor)

    if BackendAssignments.valid_page?(target.id, cursor, 1),
      do: Session.safe(fn -> read(config, target, options) end),
      else: Session.error(:validation, :inspect)
  end

  defp read(config, target, options) do
    with {:ok, operation} <-
           Operation.new(
             target.kubernetes_config,
             %{target.connection.budget | timeout_ms: 5000},
             :inspect
           ),
         {:ok, pods} <- Pod.inventory(operation),
         {:ok, records, next} <-
           Session.store(config, :backend_assignments, [target.id, options[:cursor], 1]),
         true <-
           BackendAssignments.valid_single_result?(target.id, options[:cursor], records, next) do
      namespace_page = Enum.take(Enum.sort_by(pods, &get_in(&1, ["metadata", "name"])), 20)

      {:ok,
       %{
         worker_id: target.id,
         backend_kind: :kubernetes,
         inventory_scope: :namespace_api_only,
         checked_at_ms: config.clock.now(),
         foreign_count: nil,
         candidates: Enum.map(records, &assigned_finding(target, pods, &1)),
         namespace_observations: Enum.map(namespace_page, &finding(config, target, &1)),
         namespace_count: length(pods),
         namespace_truncated: length(pods) > length(namespace_page),
         next_cursor: next
       }}
    else
      {:error, _} = error -> error
      _ -> Session.error(:store, :backend_assignments)
    end
  end

  defp assigned_finding(target, pods, record) do
    pod = Enum.find(pods, &(get_in(&1, ["metadata", "name"]) == record.machine_name))

    status =
      cond do
        pod != nil -> status(target, pod, record)
        record.reservation == nil -> :absent
        true -> :unresolved
      end

    %{
      machine_name: record.machine_name,
      observed_state: if(pod, do: :unknown, else: :missing),
      status: status,
      execution: Execution.key(record),
      record_version: record.version
    }
  end

  defp finding(config, target, pod) do
    name = get_in(pod, ["metadata", "name"])
    base = %{machine_name: name, observed_state: :unknown}

    case Session.store(config, :find_machine, [target.id, name]) do
      {:ok, %Execution{} = record} ->
        Map.merge(base, %{
          status: status(target, pod, record),
          execution: Execution.key(record),
          record_version: record.version
        })

      {:error, %Error{category: :not_found}} ->
        Map.put(base, :status, :foreign)

      _ ->
        Map.put(base, :status, :unavailable)
    end
  end

  defp valid_record?(target, pod, record),
    do:
      Execution.validate(record) == :ok and record.worker_id == target.id and
        record.machine_name == get_in(pod, ["metadata", "name"]) and
        Assignment.approved?(record.backend_assignment, target.kubernetes_config, record)

  defp status(target, pod, record) do
    cond do
      not valid_record?(target, pod, record) ->
        :conflict

      record.backend_receipt == nil ->
        :unresolved

      record.backend_receipt.pod_uid != get_in(pod, ["metadata", "uid"]) or
          not PodTemplate.matches?(pod, record.backend_assignment) ->
        :conflict

      record.reservation == nil ->
        :cleanup_conflict

      true ->
        :owned
    end
  end
end
