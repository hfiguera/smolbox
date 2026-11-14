defmodule SmolBox.Kubernetes.Enrollment do
  @moduledoc false
  alias SmolBox.Kubernetes.{Client, Operation, Shape}

  def observe(operation) do
    config = operation.config

    with {:ok, version} <- Client.request(operation, "GET", "/version"),
         true <- version["gitVersion"] == config.runtime_identity["k3s_version"],
         {:ok, anchor} <- Client.request(operation, "GET", "/api/v1/namespaces/kube-system"),
         true <- namespace?(anchor, "kube-system", config.cluster_anchor_uid),
         {:ok, namespace} <-
           Client.request(operation, "GET", "/api/v1/namespaces/" <> config.namespace),
         true <- namespace?(namespace, config.namespace, config.namespace_uid),
         {:ok, node} <- Client.request(operation, "GET", "/api/v1/nodes/" <> config.node_name),
         true <- node?(node, config),
         {:ok, runtime} <-
           Client.request(
             operation,
             "GET",
             "/apis/node.k8s.io/v1/runtimeclasses/" <> config.runtime_class
           ),
         {:ok, policy} <-
           Client.request(
             operation,
             "GET",
             "/apis/networking.k8s.io/v1/namespaces/" <>
               config.namespace <> "/networkpolicies/offline"
           ),
         true <- runtime?(runtime, config) and policy?(policy, config),
         true <- policy_digest(runtime, policy) == config.runtime_policy_digest do
      :ok
    else
      {:error, _} = error -> error
      _ -> Operation.error(:identity_conflict, operation.name, :not_dispatched)
    end
  rescue
    _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
  end

  def scope(operation) do
    config = operation.config

    with {:ok, anchor} <- Client.request(operation, "GET", "/api/v1/namespaces/kube-system"),
         true <- get_in(anchor, ["metadata", "uid"]) == config.cluster_anchor_uid,
         {:ok, namespace} <-
           Client.request(operation, "GET", "/api/v1/namespaces/" <> config.namespace),
         true <- get_in(namespace, ["metadata", "uid"]) == config.namespace_uid do
      :ok
    else
      {:error, _} = error -> error
      _ -> Operation.error(:identity_conflict, operation.name, :not_dispatched)
    end
  rescue
    _ -> Operation.error(:protocol, operation.name, :dispatch_uncertain)
  end

  def policy_digest(runtime, policy),
    do:
      Shape.digest(
        {:kubernetes_policy, 1, Map.take(runtime, ["handler", "overhead", "scheduling"]),
         get_in(policy, ["metadata", "uid"]), policy_spec(policy["spec"])}
      )

  defp namespace?(object, name, uid),
    do: identity?(object, name, uid) and get_in(object, ["status", "phase"]) == "Active"

  defp identity?(object, name, uid),
    do:
      get_in(object, ["metadata", "name"]) == name and get_in(object, ["metadata", "uid"]) == uid and
        get_in(object, ["metadata", "deletionTimestamp"]) == nil

  defp node?(object, config) do
    info = get_in(object, ["status", "nodeInfo"]) || %{}
    labels = get_in(object, ["metadata", "labels"]) || %{}

    identity?(object, config.node_name, config.node_uid) and node_info?(info, config) and
      node_labels?(labels, config) and get_in(object, ["spec", "unschedulable"]) != true and
      ready?(get_in(object, ["status", "conditions"])) and
      schedulable?(get_in(object, ["spec", "taints"]) || [])
  end

  defp node_info?(info, config),
    do:
      Map.take(
        info,
        ~w(bootID architecture operatingSystem kubeletVersion containerRuntimeVersion)
      ) ==
        %{
          "bootID" => config.node_boot_id,
          "architecture" => "amd64",
          "operatingSystem" => "linux",
          "kubeletVersion" => config.runtime_identity["k3s_version"],
          "containerRuntimeVersion" =>
            "containerd://" <> config.runtime_identity["containerd_version"]
        }

  defp node_labels?(labels, config),
    do:
      Map.take(labels, ~w(kubernetes.io/hostname kubernetes.io/arch smolvm-runtime)) ==
        %{
          "kubernetes.io/hostname" => config.node_name,
          "kubernetes.io/arch" => "amd64",
          "smolvm-runtime" => "true"
        }

  defp ready?(conditions) when is_list(conditions),
    do:
      Enum.all?(
        [
          {"Ready", "True"},
          {"MemoryPressure", "False"},
          {"DiskPressure", "False"},
          {"PIDPressure", "False"}
        ],
        fn {kind, value} ->
          Enum.filter(conditions, &(&1["type"] == kind)) |> Enum.map(& &1["status"]) == [value]
        end
      )

  defp ready?(_), do: false

  defp schedulable?(taints),
    do: Enum.all?(taints, &(&1["effect"] not in ["NoSchedule", "NoExecute"]))

  defp runtime?(object, config),
    do:
      identity?(object, config.runtime_class, config.runtime_class_uid) and
        object["handler"] == "smolvm" and
        object["overhead"] == %{"podFixed" => %{"cpu" => "250m", "memory" => "512Mi"}} and
        object["scheduling"] == %{
          "nodeSelector" => %{
            "kubernetes.io/hostname" => config.node_name,
            "kubernetes.io/arch" => "amd64",
            "smolvm-runtime" => "true"
          }
        }

  defp policy?(object, config),
    do:
      get_in(object, ["metadata", "name"]) == "offline" and
        get_in(object, ["metadata", "namespace"]) == config.namespace and
        Shape.uid?(get_in(object, ["metadata", "uid"])) and
        get_in(object, ["metadata", "deletionTimestamp"]) == nil and
        policy_spec(object["spec"]) == %{
          "podSelector" => %{},
          "policyTypes" => ["Egress", "Ingress"],
          "ingress" => [],
          "egress" => []
        }

  defp policy_spec(spec) when is_map(spec),
    do:
      spec
      |> Map.put_new("ingress", [])
      |> Map.put_new("egress", [])
      |> Map.update("policyTypes", [], &Enum.sort/1)

  defp policy_spec(_), do: nil
end
