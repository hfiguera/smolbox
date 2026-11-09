defmodule SmolBox.Embedded.NativeBranchDeletion do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchDeletionResolution,
    NativeBranchDeletionState,
    NativeReleasedBranchDeletion
  }

  alias SmolBox.Validation
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  defdelegate required?(record), to: NativeBranchDeletionState

  def resolvable?(record), do: eligible?(record) or NativeReleasedBranchDeletion.eligible?(record)

  def eligible?(record),
    do: NativeBranchDeletionState.pending?(record) and held_origin?(record)

  defp held_origin?(%{
         branch: %{
           state: :held,
           native_authority: %{completion: %BranchCompletion{held: true}, release: nil}
         }
       }),
       do: true

  defp held_origin?(_), do: false

  def intent(authority, version, delete_version, receipt) do
    digest =
      BranchCanonical.digest([
        "smolbox-native-held-delete-resolution-v1",
        authority.fingerprint,
        version,
        delete_version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(BranchCompletion.to_wire(authority.completion), :completion)
      ])

    request = %{
      "completion" => BranchCompletion.to_wire(authority.completion),
      "child" => receipt,
      "operation_id" => "resolve-delete-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", BranchDeletionResolution.request_digest(request))
  end

  def valid?(
        %__MODULE__{} = saved,
        %{completion: %BranchCompletion{held: true}, release: nil} = authority
      ),
      do:
        Validation.struct_shape?(saved, __MODULE__) and version?(saved.version) and
          version?(saved.delete_version) and
          BranchDeletionResolution.request?(saved.request) and
          saved.request ==
            intent(authority, saved.version, saved.delete_version, saved.request["child"]) and
          (saved.proof == nil or
             (is_struct(saved.proof, BranchDeletionResolution) and
                BranchDeletionResolution.matches?(saved.proof, saved.request)))

  def valid?(%NativeReleasedBranchDeletion{} = saved, authority),
    do: NativeReleasedBranchDeletion.valid?(saved, authority)

  def valid?(_, _), do: false

  def record?(%{branch: %{native_authority: %{deletion: nil}}}, _historical?), do: true

  def record?(
        %{branch: %{native_authority: %{deletion: %__MODULE__{} = saved} = authority}} = child,
        historical?
      ) do
    valid?(saved, authority) and NativeBranchDeletionState.bound_record?(child, saved) and
      if(saved.proof == nil,
        do: eligible?(child) or historical?.(child, :held),
        else: completed_state?(child)
      )
  end

  def record?(
        %{branch: %{native_authority: %{deletion: %NativeReleasedBranchDeletion{}}}} = child,
        historical?
      ),
      do: NativeReleasedBranchDeletion.record?(child, historical?)

  def record?(_, _), do: false

  def completed_state?(child),
    do: NativeBranchDeletionState.completed?(child, [:held, :retired, :closed])

  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)

  def preserved?(nil, nil, _), do: true

  def preserved?(before, %NativeReleasedBranchDeletion{} = next, version),
    do: NativeReleasedBranchDeletion.preserved?(before, next, version)

  def preserved?(nil, %__MODULE__{version: version, proof: nil}, version), do: true

  def preserved?(%__MODULE__{proof: nil} = saved, %__MODULE__{} = next, _),
    do: %{next | proof: nil} == saved

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false

  def matches?(%__MODULE__{request: request}, %BranchDeletionResolution{} = proof),
    do: BranchDeletionResolution.matches?(proof, request)

  def matches?(%NativeReleasedBranchDeletion{} = saved, proof),
    do: NativeReleasedBranchDeletion.matches?(saved, proof)

  def matches?(_, _), do: false

  def acknowledged?(%{deletion: %{proof: proof} = saved} = authority),
    do: proof != nil and valid?(saved, authority) and matches?(saved, proof)

  def acknowledged?(_), do: false
end
