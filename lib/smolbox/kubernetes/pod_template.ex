defmodule SmolBox.Kubernetes.PodTemplate do
  @moduledoc false
  alias SmolBox.Kubernetes.Assignment

  @pod_defaults %{
    "dnsPolicy" => "ClusterFirst",
    "schedulerName" => "default-scheduler",
    "serviceAccountName" => "default",
    "serviceAccount" => "default",
    "securityContext" => %{},
    "priority" => 0,
    "preemptionPolicy" => "PreemptLowerPriority",
    "volumes" => [],
    "imagePullSecrets" => [],
    "hostNetwork" => false,
    "hostPID" => false,
    "hostIPC" => false,
    "shareProcessNamespace" => false
  }
  @container_defaults %{
    "terminationMessagePath" => "/dev/termination-log",
    "terminationMessagePolicy" => "File",
    "args" => [],
    "env" => [],
    "envFrom" => [],
    "volumeMounts" => [],
    "volumeDevices" => [],
    "ports" => [],
    "stdin" => false,
    "stdinOnce" => false,
    "tty" => false
  }

  def matches?(object, assignment) do
    expected = Assignment.manifest(assignment)

    object["apiVersion"] == "v1" and object["kind"] == "Pod" and
      metadata?(object["metadata"], expected["metadata"]) and
      spec?(object["spec"], expected["spec"], assignment.binding)
  rescue
    _ -> false
  end

  def metadata?(observed, expected) when is_map(observed),
    do:
      observed["name"] == expected["name"] and observed["namespace"] == expected["namespace"] and
        subset?(observed["labels"], expected["labels"]) and
        subset?(observed["annotations"], expected["annotations"]) and
        Map.get(observed, "ownerReferences", []) == []

  def metadata?(_, _), do: false

  defp subset?(observed, expected) when is_map(observed),
    do: Map.take(observed, Map.keys(expected)) == expected

  defp subset?(_, _), do: false

  defp spec?(observed, expected, binding) when is_map(observed) do
    selector = Map.put(expected["nodeSelector"], "smolvm-runtime", "true")
    expected = Map.put(expected, "nodeSelector", selector)

    with true <- observed["nodeName"] in [nil, binding.node_name],
         true <- observed["overhead"] == %{"cpu" => "250m", "memory" => "512Mi"},
         true <- tolerations?(Map.get(observed, "tolerations", [])),
         [container] <- observed["containers"],
         [wanted] <- expected["containers"],
         true <- container?(container, wanted) do
      observed = Map.drop(observed, ["nodeName", "overhead", "tolerations", "containers"])
      expected = Map.delete(expected, "containers")
      defaults?(observed, expected, @pod_defaults)
    else
      _ -> false
    end
  end

  defp spec?(_, _, _), do: false

  defp container?(observed, expected) when is_map(observed) do
    observed = Map.update(observed, "resources", nil, &resources/1)
    defaults?(observed, expected, @container_defaults)
  end

  defp container?(_, _), do: false

  defp defaults?(observed, expected, defaults) do
    known = Map.keys(expected) ++ Map.keys(defaults)

    Map.keys(observed) -- known == [] and Map.take(observed, Map.keys(expected)) == expected and
      Enum.all?(defaults, fn {key, value} -> Map.get(observed, key, value) == value end)
  end

  defp resources(value) when is_map(value),
    do: Map.new(value, fn {key, quantity} -> {key, quantity(quantity)} end)

  defp resources(_), do: nil

  defp quantity(%{"cpu" => cpu, "memory" => memory} = value)
       when map_size(value) == 2 and cpu in ["2", "2000m"] and memory in ["1Gi", "1024Mi"],
       do: %{"cpu" => "2", "memory" => "1024Mi"}

  defp quantity(value), do: value

  defp tolerations?(value) when is_list(value),
    do:
      value == [] or
        Enum.sort(value) ==
          Enum.sort(
            Enum.map(
              ["node.kubernetes.io/not-ready", "node.kubernetes.io/unreachable"],
              &%{
                "key" => &1,
                "operator" => "Exists",
                "effect" => "NoExecute",
                "tolerationSeconds" => 300
              }
            )
          )

  defp tolerations?(_), do: false
end
