defmodule SmolBox.Embedded.CreationFeatures do
  @moduledoc false
  alias SmolBox.Embedded.{Config, Shape}
  alias SmolBox.{ExecutionSpec, NetworkPolicy, PortMapping, Validation, Workload}

  def from_spec(spec) do
    ports = Map.get(spec, :ports, [])
    workload = Map.get(spec, :workload)

    if spec.profile.network == :offline and ports == [] and workload == nil do
      nil
    else
      %{
        "network" => network(spec.profile.network),
        "ports" => PortMapping.to_wire(ports),
        "workload" => workload(workload)
      }
    end
  end

  def valid?(value),
    do:
      Shape.keys?(value, ~w(network ports workload)) and network?(value["network"]) and
        ports?(value["ports"]) and workload?(value["workload"])

  def approved?(nil, _config), do: true

  def approved?(value, config) do
    sdk = Config.sdk_identity(config)

    valid?(value) and is_map(sdk) and
      Enum.any?(~w(networking ports workloads), &(sdk["feature_versions"][&1] == 1)) and
      (not value["network"]["enabled"] or sdk["feature_versions"]["networking"] == 1) and
      (value["ports"] == [] or sdk["feature_versions"]["ports"] == 1) and
      (value["workload"] == nil or sdk["feature_versions"]["workloads"] == 1)
  end

  def attach(create, nil), do: create
  def attach(create, features), do: Map.put(create, "features", features)
  def matches?(create, spec, retained \\ nil)
  def matches?(create, spec, nil), do: Map.get(create, "features") == from_spec(spec)

  # Retained commands carry the machine's original assignment. Their public
  # ExecutionSpec selects its profile/artifact, not another startup workload or
  # port mapping. Receipt-bound observations must still match that assignment.
  def matches?(create, %ExecutionSpec{scope: scope} = spec, {scope, id}) do
    Validation.identifier?(id) and
      case Map.get(create, "features") do
        nil -> spec.profile.network == :offline
        features -> valid?(features) and features["network"] == network(spec.profile.network)
      end
  end

  def matches?(_create, _spec, _retained), do: false

  def ports(create) do
    case Map.get(create, "features") do
      nil ->
        []

      features ->
        {:ok, ports} = PortMapping.from_wire(features["ports"])
        ports
    end
  end

  def observation_matches?(create, %{network: actual, ports: ports}) do
    expected = Map.get(create, "features")

    NetworkPolicy.valid?(actual) and PortMapping.canonical?(ports) and
      network(actual) == if(expected, do: expected["network"], else: network(:offline)) and
      ports == ports(create)
  end

  def observation_matches?(_create, _machine), do: false

  def configuration?(value) do
    Shape.keys?(value, ~w(network ports backend)) and
      valid?(%{"network" => value["network"], "ports" => value["ports"], "workload" => nil}) and
      (value["backend"] == "virtio-net" or
         (value["backend"] == nil and not value["network"]["enabled"] and value["ports"] == []))
  end

  def observed(value) do
    with true <- configuration?(value),
         {:ok, ports} <- PortMapping.from_wire(value["ports"]),
         {:ok, network} <- decode_network(value["network"]) do
      {:ok, network, ports}
    else
      _invalid -> :error
    end
  end

  def network(:offline), do: %{"enabled" => false, "hosts" => [], "cidrs" => []}

  def network(%NetworkPolicy{} = policy),
    do: %{"enabled" => true, "hosts" => policy.hosts, "cidrs" => policy.cidrs}

  defp decode_network(%{"enabled" => false}), do: {:ok, :offline}
  defp decode_network(value), do: NetworkPolicy.new(hosts: value["hosts"], cidrs: value["cidrs"])

  defp network?(value) do
    Shape.keys?(value, ~w(enabled hosts cidrs)) and is_boolean(value["enabled"]) and
      case decode_network(value) do
        {:ok, policy} -> network(policy) == value
        _invalid -> false
      end
  end

  defp ports?(value) do
    case PortMapping.from_wire(value) do
      {:ok, ports} -> PortMapping.to_wire(ports) == value
      _invalid -> false
    end
  end

  defp workload(nil), do: nil

  defp workload(workload),
    do: %{
      "entrypoint" => workload.entrypoint,
      "cmd" => workload.cmd,
      "env" => Map.new(workload.env),
      "workdir" => workload.workdir
    }

  defp workload?(nil), do: true

  defp workload?(value) do
    Shape.keys?(value, ~w(entrypoint cmd env workdir)) and is_map(value["env"]) and
      case Workload.new(
             entrypoint: value["entrypoint"],
             cmd: value["cmd"],
             env: Map.to_list(value["env"]),
             workdir: value["workdir"]
           ) do
        {:ok, result} -> workload(result) == value
        _invalid -> false
      end
  end
end
