defmodule SmolBox.Backend.EmbeddedVolume do
  @moduledoc false
  alias SmolBox.Backend.{Budget, EmbeddedContext, EmbeddedReply}
  alias SmolBox.Embedded.{Call, Request, VolumeContract}
  alias SmolBox.{Error, Volume}

  def run(context, action, budget) do
    with true <- EmbeddedContext.volume_scoped?(context),
         {:ok, request, budget} <- request(context.volume, action, budget),
         do: decode(context.volume, request, Call.run(context, request, budget)),
         else: (
           {:error, _} = error -> error
           _ -> error(:identity_conflict, :not_dispatched)
         )
  end

  # Pure construction is also used by recovery models. Capability/catalog
  # approval belongs to the scoped context before Call dispatch.
  def request(%Volume{} = volume, action, budget) do
    with :ok <- Volume.validate(volume),
         true <- volume.native_authority != nil and action_allowed?(volume, action),
         true <- Budget.valid?(budget) do
      build(volume, action, budget)
    else
      _ -> error(:validation, :not_dispatched)
    end
  end

  def request(_, _, _), do: error(:validation, :not_dispatched)

  defp build(volume, action, budget) do
    request = %{
      "operation" => "volume",
      "request" => %{
        "policy_id" => volume.policy.id,
        "intent" => %{
          "worker_volume_id" => volume.worker_volume_id,
          "size_gb" => volume.size_gb
        },
        "action" => action
      }
    }

    ceiling = if Request.observation?(request), do: 30_000, else: 86_400_000

    with {:ok, budget} <-
           Budget.constrain(budget, timeout_ms: ceiling, max_response_bytes: 16_384),
         true <- Request.valid?(request, budget.timeout_ms, 2),
         do: {:ok, request, budget},
         else: (_ -> error(:validation, :not_dispatched))
  end

  def decode(_volume, request, {:ok, %{"result" => "error"} = outcome, output, nil}),
    do: EmbeddedReply.decode(nil, :volume, request, {:ok, outcome, output, nil})

  def decode(
        %Volume{native_authority: %{binding: binding}} = volume,
        request,
        {:ok, outcome, output, nil}
      )
      when output == %{stdout: <<>>, stderr: <<>>, file: <<>>} do
    domain = %{"target_id" => binding.target_id, "generation" => binding.generation}

    if Volume.validate(volume) == :ok and
         VolumeContract.matches?(outcome, request["request"], domain) and
         VolumeContract.approved_result?(outcome, volume.policy) and saved_proof?(volume, outcome),
       do: {:ok, outcome},
       else: error(:identity_conflict, :dispatch_uncertain)
  end

  def decode(_volume, _request, {:error, %Error{} = error}),
    do: {:error, %{error | operation: :volume}}

  def decode(_, _, _), do: error(:identity_conflict, :dispatch_uncertain)

  defp saved_proof?(volume, %{"volume" => %{"status" => status, "proof" => proof}})
       when status in ~w(provisioned qualified),
       do: volume.native_authority.provision in [nil, proof]

  defp saved_proof?(volume, %{"volume" => %{"status" => "deleted", "proof" => proof}}),
    do:
      volume.native_authority.abort == nil and
        volume.native_authority.provision in [nil, proof["provision"]] and
        volume.native_authority.deletion in [nil, proof]

  defp saved_proof?(volume, %{"volume" => %{"status" => "aborted", "proof" => proof}}),
    do:
      volume.native_authority.provision == nil and volume.native_authority.deletion == nil and
        volume.native_authority.abort in [nil, proof]

  defp saved_proof?(_volume, _outcome), do: true

  defp action_allowed?(_volume, %{"action" => action})
       when action in ~w(inspect_provision inspect_deletion inspect_abort), do: true

  defp action_allowed?(%{state: :creating}, %{"action" => "provision"}), do: true

  defp action_allowed?(%{state: :ready}, %{"action" => "qualify_deletion"}), do: true

  defp action_allowed?(%{state: :deleting}, %{"action" => action})
       when action in ~w(delete resolve_deletion abort_staging), do: true

  defp action_allowed?(_, _), do: false

  defp error(category, evidence),
    do: {:error, %Error{category: category, operation: :volume, evidence: evidence}}
end
