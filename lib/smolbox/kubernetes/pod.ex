defmodule SmolBox.Kubernetes.Pod do
  @moduledoc false
  alias SmolBox.{Error, Execution, Validation}

  alias SmolBox.Kubernetes.{
    Assignment,
    Client,
    Config,
    Enrollment,
    Operation,
    PodTemplate,
    Receipt,
    Shape
  }

  # Only the caller holding the successful pending -> dispatched store write
  # may call this once. Recovery calls reconcile/2 and never sends another POST.
  def create_once(operation, record) do
    with :ok <- assigned(operation, record),
         true <- record.backend_create_state == :dispatched and record.backend_receipt == nil,
         :ok <- Enrollment.observe(operation),
         {:ok, object} <-
           Client.request(
             operation,
             "POST",
             path(record.backend_assignment),
             Assignment.manifest(record.backend_assignment)
           ) do
      initial_receipt(operation, record.backend_assignment, object, :post)
    else
      {:error, _} = error -> error
      _ -> conflict(operation)
    end
  end

  def reconcile(operation, record) do
    with :ok <- assigned(operation, record),
         true <- record.backend_create_state == :dispatched,
         :ok <- Enrollment.observe(operation),
         {:ok, object} <- Client.request(operation, "GET", object_path(record.backend_assignment)) do
      reconcile_receipt(operation, record, object)
    else
      {:error, _} = error -> error
      _ -> conflict(operation)
    end
  end

  def observe(operation, record) do
    with :ok <- owned(operation, record),
         :ok <- Enrollment.observe(operation),
         {:ok, object} <- Client.request(operation, "GET", object_path(record.backend_assignment)),
         true <- same_uid?(object, record.backend_receipt),
         true <- PodTemplate.matches?(object, record.backend_assignment),
         true <- get_in(object, ["metadata", "deletionTimestamp"]) == nil do
      readiness(operation, object, record.backend_receipt)
    else
      {:error, _} = error -> error
      _ -> conflict(operation)
    end
  rescue
    _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
  end

  def await_ready(operation, record) do
    with :ok <- owned(operation, record),
         :ok <- Enrollment.observe(operation),
         do: await_initial(operation, record)
  end

  defp await_initial(operation, record) do
    with {:ok, object} <- Client.request(operation, "GET", object_path(record.backend_assignment)),
         true <-
           same_uid?(object, record.backend_receipt) and
             PodTemplate.matches?(object, record.backend_assignment),
         true <- get_in(object, ["metadata", "deletionTimestamp"]) == nil do
      initial_state(operation, record, readiness(operation, object, record.backend_receipt))
    else
      {:error, _} = error -> error
      _ -> conflict(operation)
    end
  rescue
    _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
  end

  defp initial_state(operation, record, {:ok, %{phase: :pending}}),
    do: poll(operation, fn -> await_initial(operation, record) end)

  defp initial_state(operation, _record, {:ok, %{phase: :ready}} = result),
    do: with(:ok <- Enrollment.observe(operation), do: result)

  defp initial_state(_, _, error), do: error

  # Returns API absence only. It is never physical cleanup or capacity release.
  def delete(operation, record) do
    with :ok <- owned(operation, record),
         :ok <- Enrollment.scope(operation) do
      delete_original(operation, record)
    end
  end

  def inventory(operation) do
    with :ok <- Enrollment.scope(operation),
         do: inventory_page(operation, nil, nil, [], [])
  end

  defp assigned(operation, record) do
    with :ok <- Execution.validate(record),
         true <- Assignment.approved?(record.backend_assignment, operation.config, record),
         do: :ok,
         else: (_ -> conflict(operation))
  end

  defp owned(operation, record) do
    with :ok <- assigned(operation, record),
         true <- Receipt.matches_assignment?(record.backend_receipt, record.backend_assignment),
         true <- record.backend_receipt.binding == Config.binding(operation.config),
         do: :ok,
         else: (_ -> conflict(operation))
  end

  defp initial_receipt(operation, assignment, object, mode) do
    expected = Assignment.manifest(assignment)["metadata"]

    with true <- is_map(object) and PodTemplate.metadata?(object["metadata"], expected),
         {:ok, receipt} <- Receipt.created(assignment, get_in(object, ["metadata", "uid"])) do
      cond do
        PodTemplate.matches?(object, assignment) -> {:ok, receipt}
        mode == :post -> {:error, elem(conflict(operation), 1), receipt}
        true -> conflict(operation)
      end
    else
      _ -> conflict(operation)
    end
  end

  defp reconcile_receipt(operation, %{backend_receipt: nil} = record, object),
    do: initial_receipt(operation, record.backend_assignment, object, :reconcile)

  defp reconcile_receipt(operation, record, object) do
    if same_uid?(object, record.backend_receipt) and
         PodTemplate.matches?(object, record.backend_assignment),
       do: {:ok, record.backend_receipt},
       else: conflict(operation)
  end

  defp readiness(operation, object, receipt) do
    statuses = get_in(object, ["status", "containerStatuses"]) || []

    case statuses do
      [] when receipt.phase == :ready ->
        conflict(operation)

      [] ->
        {:ok, %{phase: :pending, receipt: receipt}}

      [%{"name" => "workload", "restartCount" => 0} = status] ->
        container_status(operation, object, status, receipt)

      _ ->
        conflict(operation)
    end
  end

  defp container_status(operation, object, status, receipt) do
    with true <- image_label?(status["image"], receipt.image_reference),
         true <- get_in(object, ["status", "initContainerStatuses"]) in [nil, []],
         true <- get_in(object, ["status", "ephemeralContainerStatuses"]) in [nil, []],
         true <- receipt.container_id in [nil, status["containerID"]] do
      ready_status(operation, object, status, receipt)
    else
      _ -> conflict(operation)
    end
  end

  defp ready_status(operation, object, status, receipt) do
    cond do
      is_map(get_in(status, ["state", "terminated"])) ->
        Operation.error(:unknown, operation.name, :not_dispatched)

      get_in(object, ["status", "phase"]) in ["Failed", "Succeeded", "Unknown"] ->
        conflict(operation)

      status["ready"] == true and is_map(get_in(status, ["state", "running"])) ->
        ready_container(operation, object, status, receipt)

      true ->
        {:ok, %{phase: :pending, receipt: receipt}}
    end
  end

  defp ready_container(operation, object, status, receipt) do
    ready = get_in(object, ["status", "conditions"]) || []
    container_id = status["containerID"]

    if running?(status) and
         get_in(object, ["spec", "nodeName"]) == receipt.binding.node_name and
         ready_condition?(ready) and
         container_id?(container_id) and status["imageID"] == receipt.image_reference do
      {:ok,
       %{phase: :ready, receipt: receipt, container_id: container_id, image_id: status["imageID"]}}
    else
      conflict(operation)
    end
  end

  defp container_id?("containerd://" <> digest), do: Validation.digest?(digest)
  defp container_id?(_), do: false

  defp running?(status),
    do: status["started"] == true and Map.keys(status["state"]) == ["running"]

  defp ready_condition?(conditions),
    do: Enum.filter(conditions, &(&1["type"] == "Ready")) |> Enum.map(& &1["status"]) == ["True"]

  # The pinned CRI reports status.image as a config digest. It is a display
  # reference, not source authority: spec.image and status.imageID must retain
  # the approved immutable platform-manifest reference, with the original ID.
  defp image_label?(value, expected) when value == expected, do: true
  defp image_label?("sha256:" <> digest, _), do: Validation.digest?(digest)
  defp image_label?(_, _), do: false

  defp delete_original(operation, record) do
    case Client.request(operation, "GET", object_path(record.backend_assignment)) do
      {:ok, object} ->
        if same_uid?(object, record.backend_receipt),
          do: dispatch_delete(operation, record),
          else: conflict(operation)

      {:error, %Error{category: :not_found}} ->
        {:ok, :api_absent}

      error ->
        error
    end
  end

  defp dispatch_delete(operation, record) do
    body = %{
      "apiVersion" => "v1",
      "kind" => "DeleteOptions",
      "gracePeriodSeconds" => 10,
      "preconditions" => %{"uid" => record.backend_receipt.pod_uid},
      "propagationPolicy" => "Background"
    }

    case Client.request(operation, "DELETE", object_path(record.backend_assignment), body) do
      {:ok, _} -> await_absence(operation, record)
      {:error, %Error{category: :not_found}} -> await_absence(operation, record)
      error -> error
    end
  end

  defp await_absence(operation, record) do
    case Client.request(operation, "GET", object_path(record.backend_assignment)) do
      {:error, %Error{category: :not_found}} ->
        {:ok, :api_absent}

      {:ok, object} ->
        continue_absence(operation, record, object)

      error ->
        error
    end
  end

  defp continue_absence(operation, record, object),
    do:
      if(same_uid?(object, record.backend_receipt),
        do: poll(operation, fn -> await_absence(operation, record) end),
        else: conflict(operation)
      )

  defp inventory_page(operation, cursor, version, objects, seen) do
    query = URI.encode_query(%{"limit" => "100", "continue" => cursor || ""})
    path = "/api/v1/namespaces/" <> operation.config.namespace <> "/pods?" <> query

    with {:ok, page} <- Client.request(operation, "GET", path),
         %{"kind" => "PodList", "metadata" => metadata, "items" => items} <- page,
         true <- is_list(items) and Enum.count_until(items, 101) <= 100,
         rv when is_binary(rv) <- metadata["resourceVersion"],
         true <- byte_size(rv) in 1..128 and version in [nil, rv],
         token when is_binary(token) <- Map.get(metadata, "continue", ""),
         true <-
           byte_size(token) <= 4096 and token not in seen and Enum.count_until(seen, 32) < 32,
         true <- length(objects) + length(items) <= 1024,
         true <- inventory_items?(objects ++ items, operation.config.namespace) do
      if token == "",
        do: {:ok, objects ++ items},
        else: inventory_page(operation, token, rv, objects ++ items, [token | seen])
    else
      {:error, _} = error -> error
      _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
    end
  rescue
    _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
  end

  defp inventory_items?(items, namespace) do
    valid =
      Enum.all?(items, fn item ->
        item["kind"] == "Pod" and get_in(item, ["metadata", "namespace"]) == namespace and
          Shape.uid?(get_in(item, ["metadata", "uid"])) and
          Shape.dns_label?(get_in(item, ["metadata", "name"]))
      end)

    names = Enum.map(items, &get_in(&1, ["metadata", "name"]))
    uids = Enum.map(items, &get_in(&1, ["metadata", "uid"]))
    valid and Enum.uniq(names) == names and Enum.uniq(uids) == uids
  end

  defp poll(operation, function) do
    if Operation.remaining(operation) <= 50 do
      Operation.error(:expired, operation.name, :dispatch_uncertain)
    else
      Process.sleep(min(1000, Operation.remaining(operation) - 1))
      function.()
    end
  end

  defp same_uid?(object, receipt), do: get_in(object, ["metadata", "uid"]) == receipt.pod_uid
  defp path(assignment), do: "/api/v1/namespaces/" <> assignment.binding.namespace <> "/pods"
  defp object_path(assignment), do: path(assignment) <> "/" <> assignment.pod_name

  defp conflict(operation),
    do: Operation.error(:identity_conflict, operation.name, :not_dispatched)
end
