defmodule SmolBox.BranchClient do
  @moduledoc false
  alias SmolBox.{Client, Error, Machine}

  def source(client, parent) do
    with {:ok, observed} <- Client.checkpoint_preflight(client, parent.machine_name),
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

  def release(client, child),
    do: mutate(client, child.machine_name <> "/branch-release", %{"env" => []}, child, false)

  def inspect_child(client, child, held) do
    with {:ok, raw} <- request(client, :get, child.machine_name, nil),
         {:ok, observed} <- observation(raw, child.machine_name, held),
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
         {:ok, observed} <- observation(body, child.machine_name, held),
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

  defp observation(raw, name, held) when is_map(raw) do
    with true <-
           raw["image"] in [nil, ""] and raw["branchable"] == false and
             raw["branchpointHeld"] == held,
         {:ok, %{name: ^name, state: :running, network: :offline, ports: []} = m} <-
           Machine.from_wire(raw),
         do: {:ok, m},
         else: (_ -> error(:protocol, :dispatch_uncertain))
  end

  defp observation(_, _, _), do: error(:protocol, :dispatch_uncertain)

  defp error(category, evidence),
    do: {:error, %Error{category: category, operation: :branch, evidence: evidence}}
end
