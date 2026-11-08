defmodule SmolBox.Embedded.NativePartialBranchDisposal do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    NativeBranchBacking,
    NativeBranchRetirement,
    NativePartialBranchCleanup,
    NativePartialBranchCollection,
    NativeUnbootedBranchDisposal,
    PartialBranchChildAbsence,
    PartialBranchCollection,
    PartialBranchDisposal
  }

  alias SmolBox.{ManagedMachine, Profile, Validation}
  @enforce_keys [:version, :request, :platform]
  @derive {Inspect, only: [:version, :platform]}
  defstruct @enforce_keys ++ [proof: nil, completion_version: nil, cleanup: nil]

  def new(authority, version, platform) do
    collection = authority.partial_collection

    digest =
      BranchCanonical.digest([
        "smolbox-native-partial-branch-disposal-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(collection.request, :partial_collection_request),
        BranchCanonical.ordered(
          PartialBranchCollection.to_wire(collection.proof),
          :partial_collection
        )
      ])

    request = %{
      "collection_request" => collection.request,
      "collection" => PartialBranchCollection.to_wire(collection.proof),
      "operation_id" => "dispose-partial-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    request = Map.put(request, "request_sha256", PartialBranchDisposal.request_digest(request))
    %__MODULE__{version: version, request: request, platform: platform}
  end

  def valid?(%__MODULE__{} = saved, authority),
    do:
      Validation.struct_shape?(saved, __MODULE__) and collection?(authority) and
        Validation.integer?(
          saved.version,
          authority.partial_collection.completion_version + 1,
          9_007_199_254_740_991
        ) and
        saved.platform == authority.partial_collection.platform and
        action?(saved, authority) and completion?(saved) and cleanup?(saved, authority) and
        retirement?(authority)

  def valid?(_, _), do: false

  defp action?(saved, authority),
    do:
      PartialBranchDisposal.request?(saved.request) and
        %{saved | proof: nil, completion_version: nil, cleanup: nil} ==
          new(authority, saved.version, saved.platform) and
        Enum.all?(
          ~w(completion prepared_retirement disposal release deletion delete_continuation delete_cleanup delete_collection)a,
          &(Map.fetch!(authority, &1) == nil)
        )

  defp cleanup?(%{cleanup: nil}, _), do: true

  defp cleanup?(%{cleanup: saved} = disposal, authority),
    do: NativePartialBranchCleanup.valid?(saved, %{authority | partial_disposal: disposal})

  defp retirement?(%{retirement: nil, backing: nil}), do: true

  defp retirement?(
         %{retirement: %NativeBranchRetirement{proof: %PartialBranchChildAbsence{}} = saved} =
           authority
       ),
       do: NativeBranchRetirement.valid?(saved, authority) and backing?(authority)

  defp retirement?(_), do: false
  defp backing?(%{backing: nil}), do: true

  defp backing?(%{backing: %NativeBranchBacking{} = saved} = authority),
    do: NativeBranchBacking.valid?(saved, authority)

  defp backing?(_), do: false

  defp collection?(
         %{partial_collection: %NativePartialBranchCollection{proof: proof} = saved} = a
       ),
       do: proof != nil and NativePartialBranchCollection.valid?(saved, a)

  defp collection?(_), do: false
  defp completion?(%{proof: nil, completion_version: nil}), do: true

  defp completion?(%{proof: %PartialBranchDisposal{} = proof} = saved),
    do:
      Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991) and
        PartialBranchDisposal.matches?(proof, saved.request) and
        proof.publication["change"]["platform"] == saved.platform

  defp completion?(_), do: false

  def eligible?(%ManagedMachine{branch: %{state: state, native_authority: authority}} = child),
    do:
      state in [:unknown, :disposal_pending, :disposal_cleanup_pending] and collection?(authority) and
        child.state == :unknown and child.operation == :branch_child and
        child.reservation == Profile.resources(child.spec.profile) and
        child.reserved_ports == [] and child.created_machine == nil and
        child.observed_machine == nil and child.absence_at_ms == nil

  def eligible?(_), do: false

  def pending?(parent, child) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- eligible?(child) do
      NativePartialBranchCollection.source_pending?(parent, child)
    else
      _ -> false
    end
  end

  def record?(%{branch: %{native_authority: %{partial_disposal: nil}}}), do: true

  def record?(
        %{branch: %{native_authority: %{partial_disposal: %__MODULE__{} = saved} = authority}} = c
      ),
      do:
        valid?(saved, authority) and saved.version < c.version and
          NativePartialBranchCleanup.record?(saved, c) and state?(c, saved)

  def record?(_), do: false

  defp state?(child, %{proof: nil, cleanup: nil}),
    do: child.branch.state == :disposal_pending and eligible?(child)

  defp state?(child, %{proof: nil}),
    do: child.branch.state == :disposal_cleanup_pending and eligible?(child)

  defp state?(child, saved),
    do:
      deleted_projection?(child) and
        saved.completion_version < child.version and
        NativeUnbootedBranchDisposal.plan?(saved.proof, child.spec.profile) and
        get_in(saved.proof.publication, ~w(change child_origin intent source_pid)) ==
          child.branch.source_machine.backend_identity.pid_identity

  defp deleted_projection?(child),
    do:
      child.state == :deleted and disposed_state?(child.branch) and ManagedMachine.idle?(child) and
        child.reservation == nil and child.reserved_ports == [] and child.absence_at_ms != nil and
        child.created_machine == nil and child.observed_machine == nil

  defp disposed_state?(%{state: :disposed, native_authority: %{retirement: nil}}), do: true

  defp disposed_state?(%{
         state: :retired,
         native_authority: %{
           retirement: %NativeBranchRetirement{proof: %PartialBranchChildAbsence{}}
         }
       }),
       do: true

  defp disposed_state?(%{
         state: state,
         native_authority: %{
           backing: %NativeBranchBacking{},
           retirement: %NativeBranchRetirement{proof: %PartialBranchChildAbsence{}}
         }
       })
       when state in [:backing_pending, :closed], do: true

  defp disposed_state?(_), do: false

  def preserved?(nil, nil, _), do: true

  def preserved?(
        nil,
        %__MODULE__{version: v, proof: nil, completion_version: nil, cleanup: nil},
        v
      ),
      do: true

  def preserved?(
        %__MODULE__{proof: nil, completion_version: nil} = before,
        %__MODULE__{} = after_saved,
        v
      ),
      do:
        %{after_saved | proof: nil, completion_version: nil, cleanup: nil} == %{
          before
          | cleanup: nil
        } and
          NativePartialBranchCleanup.preserved?(before.cleanup, after_saved.cleanup, v) and
          (after_saved.proof == nil or after_saved.completion_version == v)

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
