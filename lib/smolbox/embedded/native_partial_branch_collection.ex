defmodule SmolBox.Embedded.NativePartialBranchCollection do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    NativeCollectedBranchPublication,
    NativePartialBranchHistory,
    PartialBranchCollection
  }

  alias SmolBox.{ManagedMachine, ManagedMachineState, Profile, Validation}
  @enforce_keys [:version, :request, :platform]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil, completion_version: nil]

  def new(authority, version, platform) do
    digest =
      BranchCanonical.digest([
        "smolbox-native-partial-branch-collection-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(authority.request, :creation_request)
      ])

    request = %{
      "creation" => authority.request,
      "operation_id" => "collect-partial-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    request = Map.put(request, "request_sha256", PartialBranchCollection.request_digest(request))
    %__MODULE__{version: version, request: request, platform: platform}
  end

  def valid?(%__MODULE__{} = saved, authority),
    do:
      Validation.struct_shape?(saved, __MODULE__) and
        Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
        saved.platform in ~w(linux macos) and
        PartialBranchCollection.request?(saved.request) and
        %{saved | proof: nil, completion_version: nil} ==
          new(authority, saved.version, saved.platform) and
        Enum.all?(
          ~w(completion prepared_retirement disposal release deletion delete_continuation delete_cleanup delete_collection)a,
          &(Map.fetch!(authority, &1) == nil)
        ) and NativePartialBranchHistory.retirement?(authority) and
        completion?(saved)

  def valid?(_, _), do: false

  defp completion?(%{proof: nil, completion_version: nil}), do: true

  defp completion?(saved),
    do:
      is_struct(saved.proof, PartialBranchCollection) and
        PartialBranchCollection.matches?(saved.proof, saved.request) and
        Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991)

  def eligible?(
        %{
          __struct__: ManagedMachine,
          branch: %{
            state: :unknown,
            native_authority: %{
              completion: nil,
              prepared_retirement: nil,
              disposal: nil,
              release: nil
            }
          }
        } = child
      ),
      do:
        child.state == :unknown and child.operation == :branch_child and
          child.reservation == Profile.resources(child.spec.profile) and
          child.reserved_ports == [] and
          child.created_machine == nil and child.observed_machine == nil and
          child.absence_at_ms == nil

  def eligible?(_), do: false

  def source_pending?(parent, child) do
    parent.active_branch == child.id and parent.operation == :branch and
      parent.branch_children[child.id] == false and same_worker_source?(parent, child) and
      NativeCollectedBranchPublication.source_pending?(parent, child)
  end

  defp same_worker_source?(parent, child),
    do:
      parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        child.branch.source == ManagedMachineState.key(parent)

  def record?(%{branch: %{native_authority: %{partial_collection: nil}}}), do: true

  def record?(
        %{branch: %{native_authority: %{partial_collection: %__MODULE__{} = saved} = authority}} =
          child
      ),
      do:
        collection_state?(child, authority) and valid?(saved, authority) and
          saved.version < child.version and
          (saved.completion_version == nil or saved.completion_version < child.version)

  def record?(_), do: false

  defp collection_state?(child, authority),
    do:
      eligible?(child) or
        match?(
          %{__struct__: SmolBox.Embedded.NativePartialBranchDisposal},
          authority.partial_disposal
        )

  def preserved?(nil, nil, _), do: true

  def preserved?(
        nil,
        %__MODULE__{version: version, proof: nil, completion_version: nil},
        version
      ),
      do: true

  def preserved?(%__MODULE__{proof: nil} = before, %__MODULE__{} = after_action, _),
    do: %{after_action | proof: nil, completion_version: nil} == before

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
