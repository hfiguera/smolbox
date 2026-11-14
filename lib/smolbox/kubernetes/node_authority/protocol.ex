defmodule SmolBox.Kubernetes.NodeAuthority.Protocol do
  @moduledoc false
  alias SmolBox.Kubernetes.{Binding, CleanupProof, Observation, Receipt, Shape}
  alias SmolBox.Kubernetes.NodeAuthority.JSON
  alias SmolBox.Kubernetes.NodeEvidence.Projection
  alias SmolBox.Validation

  @identity ~w(binding_generation authority_generation verifier_manifest_sha256)
  @response_keys ~w(version action nonce binding_generation authority_generation verifier_manifest_sha256 ok journal value error)
  @errors %{
    "invalid_request" => :protocol,
    "identity_conflict" => :identity_conflict,
    "unavailable" => :identity_conflict,
    "expired" => :expired,
    "output_limit" => :output_limit
  }

  def request(action, binding, argument, context, budget, nonce) do
    with true <- Binding.valid?(binding) and Validation.digest?(nonce),
         {:ok, arguments} <- arguments(action, argument, binding, context) do
      request = %{
        "version" => 1,
        "action" => Atom.to_string(action),
        "nonce" => nonce,
        "binding_generation" => binding.generation,
        "authority_generation" => context.authority_generation,
        "verifier_manifest_sha256" => context.verifier_manifest_sha256,
        "timeout_ms" => min(30_000, budget.timeout_ms),
        "max_response_bytes" => min(65_544, budget.max_response_bytes),
        "arguments" => arguments
      }

      with true <- request["max_response_bytes"] >= 9,
           {:ok, body} <- JSON.encode(request),
           true <- byte_size(body) + 8 <= budget.max_request_bytes,
           do: {:ok, request, body},
           else: (_ -> {:error, :output_limit})
    else
      _ -> {:error, :identity_conflict}
    end
  end

  def response(bytes, request, binding, receipt, now, status \\ 0) do
    with {:ok, value} when is_map(value) <- JSON.decode(bytes),
         true <- Shape.exact_keys?(value, @response_keys) and value["version"] == 1,
         true <- Enum.all?(@identity ++ ~w(action nonce), &(value[&1] == request[&1])),
         true <- byte_size(bytes) + 8 <= request["max_response_bytes"],
         true <- is_boolean(value["ok"]) and Validation.integer?(status, 0, 255) do
      # A helper's exit is never an application exit. A complete authenticated
      # rejection can carry its bounded reason despite helper failure; positive
      # evidence additionally requires normal helper/channel completion.
      case {value["ok"], status} do
        {true, 0} -> success(value, request, binding, receipt, now)
        {false, _} -> rejection(value)
        _ -> {:error, :transport}
      end
    else
      _ -> {:error, :protocol}
    end
  end

  defp arguments(:check, nil, _, _), do: {:ok, %{}}

  defp arguments(:capture, pod_uid, _, _) do
    if Shape.boot_id?(pod_uid), do: {:ok, %{"pod_uid" => pod_uid}}, else: :error
  end

  defp arguments(:cleanup, receipt, binding, context) do
    with true <-
           Receipt.valid?(receipt) and receipt.phase == :ready and receipt.binding == binding,
         true <- receipt.observation.observer_epoch == context.authority_generation,
         true <- complete_observation?(receipt.observation) and Shape.boot_id?(receipt.pod_uid),
         encoded <- wire(receipt),
         {:ok, digest} <- JSON.digest(encoded),
         do: {:ok, %{"receipt" => encoded, "receipt_sha256" => digest}},
         else: (_ -> :error)
  end

  defp arguments(_, _, _, _), do: :error

  defp success(value, request, binding, receipt, now) do
    if value["error"] == nil and journal?(value["journal"]),
      do: evidence(request["action"], value["value"], request, binding, receipt, now),
      else: {:error, :protocol}
  end

  defp journal?(value),
    do:
      Shape.exact_keys?(value, ~w(history_epoch watermark prefix_sha256)) and
        Shape.boot_id?(value["history_epoch"]) and
        Validation.integer?(value["watermark"], 0, 4096) and
        Validation.digest?(value["prefix_sha256"])

  defp rejection(value) do
    with true <- value["journal"] == nil and value["value"] == nil,
         {:ok, category} <- Map.fetch(@errors, value["error"]),
         do: {:error, category},
         else: (_ -> {:error, :protocol})
  end

  defp evidence("check", value, request, _, _, _) do
    if Shape.exact_keys?(value, ~w(complete_history idle observer_epoch)) and
         value["complete_history"] == true and
         is_boolean(value["idle"]) and value["observer_epoch"] == request["authority_generation"],
       do:
         {:ok,
          %{complete_history: true, idle: value["idle"], observer_epoch: value["observer_epoch"]}},
       else: {:error, :identity_conflict}
  end

  defp evidence("capture", value, request, binding, _, now) do
    with {:ok, observation} <- Projection.observation(value),
         true <- complete_observation?(observation),
         true <- observation.observer_epoch == request["authority_generation"],
         true <-
           Observation.dispatchable?(observation, binding, request["arguments"]["pod_uid"], now),
         do: {:ok, observation},
         else: (_ -> {:error, :identity_conflict})
  end

  defp evidence("cleanup", value, request, _, receipt, now) do
    with {:ok, proof} <- Projection.cleanup(value, receipt),
         true <-
           proof.observer_epoch == request["authority_generation"] and proof.observed_at_ms <= now,
         true <- CleanupProof.releasable?(proof, receipt),
         do: {:ok, proof},
         else: (_ -> {:error, :identity_conflict})
  end

  defp complete_observation?(value),
    do:
      Observation.valid?(value) and value.complete_history == true and
        length(value.sandbox_ids) == length(value.processes) and
        length(value.processes) == length(value.interfaces)

  defp wire(value) when is_struct(value), do: value |> Map.from_struct() |> wire()

  defp wire(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), wire(item)} end)

  defp wire(value) when is_list(value), do: Enum.map(value, &wire/1)
  defp wire(value) when value in [:kubernetes, :ready], do: Atom.to_string(value)
  defp wire(value), do: value
end
