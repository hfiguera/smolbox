defmodule SmolBox.Embedded.VolumeAuthority do
  @moduledoc """
  Enrolled native volume binding and immutable lifecycle evidence for store adapters.

  Store adapters retain separate proofs for provisioning, deletion and staging
  abort. Each proof must match the saved volume and its binding before the store
  updates state or accounting. Inspect output includes only the binding.
  """
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.VolumeContract
  alias SmolBox.Validation

  @enforce_keys [:binding]
  @derive {Inspect, only: [:binding]}
  defstruct @enforce_keys ++ [provision: nil, deletion: nil, abort: nil]

  @type t :: %__MODULE__{
          binding: Binding.t(),
          provision: map() | nil,
          deletion: map() | nil,
          abort: map() | nil
        }

  def valid?(%__MODULE__{} = authority, volume),
    do:
      Validation.struct_shape?(authority, __MODULE__) and Binding.valid?(authority.binding) and
        authority.binding.target_id == volume.worker_id and proofs?(authority, volume) and
        state?(authority, volume.state)

  def valid?(_, _), do: false

  def transition?(nil, nil), do: true

  def transition?(%__MODULE__{} = previous, %__MODULE__{} = next),
    do:
      previous.binding == next.binding and
        Enum.all?([:provision, :deletion, :abort], fn field ->
          Map.fetch!(previous, field) == nil or
            Map.fetch!(previous, field) == Map.fetch!(next, field)
        end)

  def transition?(_, _), do: false

  def complete(%__MODULE__{deletion: nil, abort: nil} = authority, volume, outcome),
    do: complete_proof(authority, volume, outcome)

  def complete(_, _, _), do: :error

  defp complete_proof(
         authority,
         volume,
         %{"volume" => %{"status" => "provisioned", "proof" => proof}} = outcome
       ) do
    if authority.provision == nil and matches?(authority, volume, "provision", outcome),
      do: {:ok, %{authority | provision: proof}},
      else: :error
  end

  defp complete_proof(
         authority,
         volume,
         %{"volume" => %{"status" => "deleted", "proof" => proof}} = outcome
       ) do
    if matches?(authority, volume, "delete", outcome) and
         authority.provision in [nil, proof["provision"]],
       do: {:ok, %{authority | provision: proof["provision"], deletion: proof}},
       else: :error
  end

  defp complete_proof(
         authority,
         volume,
         %{"volume" => %{"status" => "aborted", "proof" => proof}} = outcome
       ) do
    if authority.provision == nil and matches?(authority, volume, "abort_staging", outcome),
      do: {:ok, %{authority | abort: proof}},
      else: :error
  end

  defp complete_proof(_, _, _), do: :error

  defp proofs?(authority, volume),
    do:
      optional?(authority, volume, "provisioned", authority.provision) and
        optional?(authority, volume, "deleted", authority.deletion) and
        optional?(authority, volume, "aborted", authority.abort) and linkage?(authority)

  defp optional?(_authority, _volume, _status, nil), do: true

  defp optional?(authority, volume, status, proof) do
    action = %{"provisioned" => "provision", "deleted" => "delete", "aborted" => "abort_staging"}
    matches?(authority, volume, action[status], outcome(status, proof))
  end

  defp linkage?(%{deletion: deletion, provision: provision, abort: nil}) when deletion != nil,
    do: deletion["provision"] == provision

  defp linkage?(%{abort: abort, provision: nil, deletion: nil}) when abort != nil, do: true
  defp linkage?(%{deletion: nil, abort: nil}), do: true
  defp linkage?(_), do: false

  defp state?(%{provision: nil, deletion: nil, abort: nil}, :creating), do: true

  defp state?(%{provision: provision, deletion: nil, abort: nil}, :ready),
    do: provision != nil

  defp state?(%{deletion: nil, abort: nil}, state) when state in [:deleting, :unknown], do: true
  defp state?(%{deletion: deletion, abort: nil}, :deleted) when deletion != nil, do: true
  defp state?(%{abort: abort, deletion: nil}, :deleted) when abort != nil, do: true
  defp state?(_, _), do: false

  defp outcome(status, proof),
    do: %{"result" => "volume", "volume" => %{"status" => status, "proof" => proof}}

  defp matches?(authority, volume, action, outcome) do
    action =
      if action == "abort_staging",
        do: %{"action" => action, "quiesced" => true},
        else: %{"action" => action}

    request = %{
      "policy_id" => volume.policy.id,
      "intent" => %{"worker_volume_id" => volume.worker_volume_id, "size_gb" => volume.size_gb},
      "action" => action
    }

    domain = %{
      "target_id" => authority.binding.target_id,
      "generation" => authority.binding.generation
    }

    VolumeContract.matches?(outcome, request, domain) and
      VolumeContract.approved_result?(outcome, volume.policy)
  end
end
