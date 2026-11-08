defmodule SmolBox.Runtime.NativeVolumeRecovery do
  @moduledoc false
  alias SmolBox.Backend.EmbeddedVolume
  alias SmolBox.{Error, Volume}
  alias SmolBox.Runtime.{Session, Target}

  def classify(config, target, volume) do
    with true <- bound?(volume, target),
         reference = Target.connection(target, volume),
         budget = %{reference.budget | timeout_ms: min(reference.budget.timeout_ms, 1000)},
         {:ok, outcome} <- EmbeddedVolume.run(reference.context, action(volume), budget),
         true <- observation_valid?(volume, outcome),
         do: persist(config, volume),
         else: (_ -> Session.error(:identity_conflict, :reconcile))
  end

  def bound?(%Volume{native_authority: %{binding: binding}} = volume, target),
    do:
      Volume.validate(volume) == :ok and volume.worker_id == target.id and
        Map.from_struct(binding) == target.domain_binding and
        volume.policy == target.volume_policy

  def bound?(_, _), do: false

  def action(%{state: :deleted, native_authority: %{abort: abort}}) when abort != nil,
    do: %{"action" => "inspect_abort"}

  def action(%{state: :deleted}), do: %{"action" => "inspect_deletion"}
  def action(_), do: %{"action" => "inspect_provision"}

  def observation_valid?(volume, outcome) do
    with {:ok, request, _budget} <- EmbeddedVolume.request(volume, action(volume), budget()),
         {:ok, ^outcome} <-
           EmbeddedVolume.decode(volume, request, {:ok, outcome, empty(), nil}),
         do: retained_proof?(volume, outcome),
         else: (_ -> false)
  end

  defp retained_proof?(%{state: :ready, native_authority: authority}, outcome),
    do:
      outcome["volume"]["status"] == "provisioned" and
        outcome["volume"]["proof"] == authority.provision

  defp retained_proof?(%{state: :deleted, native_authority: authority}, outcome),
    do: outcome["volume"]["proof"] == (authority.deletion || authority.abort)

  defp retained_proof?(%{native_authority: %{provision: nil}}, _outcome), do: true

  defp retained_proof?(%{native_authority: authority}, outcome),
    do:
      outcome["volume"]["status"] == "unverified" or
        outcome["volume"]["proof"] == authority.provision

  # Startup observation never imports proof or completes cleanup. CAS prevents
  # a concurrent completion/attachment from being overwritten by this snapshot.
  def persist(config, volume) do
    case Session.store(config, :volume_fetch, [Volume.key(volume)]) do
      {:ok, ^volume} -> uncertain(config, volume)
      _ -> Session.error(:stale_version, :reconcile)
    end
  end

  defp uncertain(config, %{state: state} = volume) when state in [:creating, :deleting] do
    error = %Error{category: :unknown, operation: :volume, evidence: :unknown}

    case Session.store(config, :volume_change, [
           Volume.key(volume),
           volume.version,
           {:unknown, error},
           config.clock.now()
         ]) do
      {:ok, _, :changed} -> :ok
      _ -> Session.error(:stale_version, :reconcile)
    end
  end

  defp uncertain(_config, _volume), do: :ok
  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp budget,
    do: %SmolBox.Backend.Budget{
      timeout_ms: 1000,
      max_request_bytes: 16_384,
      max_response_bytes: 16_384
    }
end
