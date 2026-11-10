defmodule SmolBox.BranchClient do
  @moduledoc false
  alias SmolBox.{BranchHTTPSCredentials, Client, Error, Machine}

  def source(client, parent) do
    with {:ok, observed} <-
           Client.checkpoint_preflight(client, parent.machine_name, parent.spec.profile.network),
         true <- Machine.same_incarnation?(parent.created_machine, observed),
         do: {:ok, observed},
         else: (
           {:error, _} = error -> error
           _ -> error(:identity_conflict, :not_dispatched)
         )
  end

  def create(client, source, child) do
    wire = %{
      "name" => child.machine_name,
      "branchable" => false,
      "freezeSource" => false,
      "hold" => child.branch.spec.hold,
      "waitReady" => child.branch.spec.hold,
      "readyTimeoutSecs" => max(div(child.branch.spec.timeout_ms, 1000), 1),
      "ports" => [],
      "env" => [],
      "secrets" => %{},
      "shareWeights" => false
    }

    mutate(client, source.machine_name <> "/branches", wire, child, child.branch.spec.hold)
  end

  def release(client, child) do
    env = Enum.map(child.branch.release_env, fn {name, value} -> name <> "=" <> value end)
    mutate(client, child.machine_name <> "/branch-release", %{"env" => env}, child, false)
  end

  def install_https_credential(client, child, token) do
    if BranchHTTPSCredentials.secure_transport?(client.worker) do
      case client.transport.request(client.worker, %{
             method: :put,
             path: "/api/v1/machines/" <> child.machine_name <> "/credential-values",
             body: Jason.encode!(BranchHTTPSCredentials.values(token)),
             content_type: "application/json",
             accept: "*/*",
             max_bytes: 1,
             expected_status: 204,
             mode: :empty
           }) do
        {:ok, ""} -> :ok
        _ -> error(:authentication, :dispatch_uncertain)
      end
    else
      BranchHTTPSCredentials.unavailable()
    end
  rescue
    _ -> BranchHTTPSCredentials.unavailable()
  catch
    _, _ -> BranchHTTPSCredentials.unavailable()
  end

  def inspect_child(client, child, held) do
    with {:ok, raw} <- request(client, :get, child.machine_name, nil),
         {:ok, observed} <- observation(raw, child, held),
         true <-
           child.created_machine != nil and
             Machine.same_incarnation?(child.created_machine, observed),
         do: {:ok, observed},
         else: (
           {:error, _} = error -> error
           _ -> error(:identity_conflict, :not_dispatched)
         )
  end

  def absent(client, name) do
    case Client.inspect_machine(client, name) do
      {:error, %{category: :not_found}} -> {:ok, :absent}
      {:error, _} = error -> error
      _ -> error(:identity_conflict, :not_dispatched)
    end
  end

  defp mutate(client, suffix, wire, child, held) do
    with {:ok, body} <- request(client, :post, suffix, wire),
         {:ok, observed} <- observation(body, child, held),
         do: {:ok, observed},
         else: (_ -> error(:unknown, :dispatch_uncertain))
  end

  defp request(client, method, suffix, wire) do
    with {:ok, body} <-
           client.transport.request(client.worker, %{
             method: method,
             path: "/api/v1/machines/" <> suffix,
             body: if(wire == nil, do: "", else: Jason.encode!(wire)),
             content_type: "application/json",
             accept: "application/json",
             max_bytes: 1_048_576,
             mode: :buffer
           }),
         {:ok, raw} <- Jason.decode(body),
         do: {:ok, raw},
         else: (
           {:error, %Error{}} = error -> error
           _ -> error(:protocol, :dispatch_uncertain)
         )
  end

  defp observation(raw, child, held) when is_map(raw) do
    name = child.machine_name
    network = child.spec.profile.network

    with true <-
           raw["image"] in [nil, ""] and raw["branchable"] == false and
             raw["branchpointHeld"] == held and
             (network == :offline or raw["parentMachine"] == child.branch.source_machine.name),
         {:ok, %{name: ^name, state: :running, network: ^network, ports: []} = m} <-
           Machine.from_wire(raw),
         do: {:ok, m},
         else: (_ -> error(:protocol, :dispatch_uncertain))
  end

  defp observation(_, _, _), do: error(:protocol, :dispatch_uncertain)

  defp error(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}
end
