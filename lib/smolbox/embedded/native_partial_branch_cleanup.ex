defmodule SmolBox.Embedded.NativePartialBranchCleanup do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded
  }

  alias SmolBox.Validation
  @enforce_keys [:version, :request, :platform]
  @derive {Inspect, only: [:version, :platform]}
  defstruct @enforce_keys ++ [proof: nil, completion_version: nil, unneeded: nil]

  def new(authority, version, platform) do
    disposal = authority.partial_disposal

    digest =
      BranchCanonical.digest([
        "smolbox-native-partial-branch-cleanup-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(disposal.request, :partial_disposal_request)
      ])

    request = %{
      "disposal_request" => disposal.request,
      "operation_id" => "cleanup-partial-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    request =
      Map.put(request, "request_sha256", PartialBranchDisposalCleanup.request_digest(request))

    %__MODULE__{version: version, request: request, platform: platform}
  end

  # The containing disposal validates collection and the full authority. Do not
  # recurse into that validator from this nested action.
  def valid?(%__MODULE__{} = saved, %{partial_disposal: disposal} = authority)
      when not is_nil(disposal),
      do:
        Validation.struct_shape?(saved, __MODULE__) and
          Validation.integer?(saved.version, disposal.version + 1, 9_007_199_254_740_991) and
          saved.platform == disposal.platform and
          PartialBranchDisposalCleanup.request?(saved.request) and
          %{saved | proof: nil, completion_version: nil, unneeded: nil} ==
            new(authority, saved.version, saved.platform) and
          completion?(saved, disposal)

  def valid?(_, _), do: false

  defp completion?(%{proof: nil, unneeded: nil, completion_version: nil}, %{
         proof: nil,
         completion_version: nil
       }),
       do: true

  defp completion?(
         %{proof: %PartialBranchDisposalCleanup{} = proof, unneeded: nil} = saved,
         disposal
       ),
       do:
         Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991) and
           saved.completion_version == disposal.completion_version and
           PartialBranchDisposalCleanup.matches?(proof, saved.request) and
           is_struct(disposal.proof, PartialBranchDisposal) and
           proof.disposal == PartialBranchDisposal.to_wire(disposal.proof)

  defp completion?(
         %{proof: nil, unneeded: %PartialBranchDisposalCleanupUnneeded{} = proof} = saved,
         disposal
       ),
       do:
         Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991) and
           saved.completion_version == disposal.completion_version and
           PartialBranchDisposalCleanupUnneeded.matches?(proof, saved.request) and
           is_struct(disposal.proof, PartialBranchDisposal) and
           proof.disposal == PartialBranchDisposal.to_wire(disposal.proof)

  defp completion?(_, _), do: false

  def record?(%{cleanup: nil}, _), do: true

  def record?(%{cleanup: %__MODULE__{} = saved}, child),
    do: saved.version < child.version

  def record?(_, _), do: false

  def preserved?(nil, nil, _), do: true

  def preserved?(
        nil,
        %__MODULE__{version: v, proof: nil, unneeded: nil, completion_version: nil},
        v
      ),
      do: true

  def preserved?(
        %__MODULE__{proof: nil, unneeded: nil, completion_version: nil} = before,
        %__MODULE__{} = after_saved,
        v
      ),
      do:
        %{after_saved | proof: nil, unneeded: nil, completion_version: nil} == before and
          ((after_saved.proof == nil and after_saved.unneeded == nil) or
             after_saved.completion_version == v)

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
