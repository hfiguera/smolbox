defmodule SmolBox.Embedded.NativeBranchDeletionAction do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchDeletionContinuation,
    BranchDeletionResolution,
    HeldBranchDeletionAction,
    NativeBranchDeletion,
    NativeBranchDeletionCollection,
    NativeBranchDeletionState,
    NativeReleasedBranchDeletion,
    NativeReleasedBranchDeletionCleanup,
    NativeReleasedBranchDeletionContinuation
  }

  alias SmolBox.Validation
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  def field(:collect), do: :delete_collection

  def field(:continue), do: :delete_continuation
  def field(:cleanup), do: :delete_cleanup

  def eligible?(child, :continue),
    do:
      NativeBranchDeletion.eligible?(child) or
        NativeReleasedBranchDeletionContinuation.eligible?(child)

  def eligible?(child, :cleanup),
    do:
      NativeBranchDeletion.eligible?(child) or
        NativeReleasedBranchDeletionCleanup.eligible?(child)

  def eligible?(child, :collect), do: NativeBranchDeletionCollection.eligible?(child)

  def eligible?(_, _), do: false

  def intent(authority, action, version, delete_version, receipt) do
    digest =
      BranchCanonical.digest([
        "smolbox-native-held-delete-action-v1",
        Atom.to_string(action),
        authority.fingerprint,
        version,
        delete_version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(BranchCompletion.to_wire(authority.completion), :completion)
      ])

    request = %{
      "action" => Atom.to_string(action),
      "completion" => BranchCompletion.to_wire(authority.completion),
      "child" => receipt,
      "operation_id" => "delete-#{action}-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", HeldBranchDeletionAction.request_digest(request))
  end

  def valid?(
        %__MODULE__{} = saved,
        %{completion: %BranchCompletion{held: true}, release: nil} = authority,
        action
      )
      when action in [:continue, :cleanup],
      do:
        Validation.struct_shape?(saved, __MODULE__) and version?(saved.version) and
          version?(saved.delete_version) and saved.delete_version <= saved.version and
          HeldBranchDeletionAction.request?(saved.request, Atom.to_string(action)) and
          saved.request ==
            intent(authority, action, saved.version, saved.delete_version, saved.request["child"]) and
          (saved.proof == nil or matches?(saved, action, saved.proof))

  def valid?(%NativeReleasedBranchDeletionContinuation{} = saved, authority, :continue),
    do: NativeReleasedBranchDeletionContinuation.valid?(saved, authority, :continue)

  def valid?(%NativeReleasedBranchDeletionCleanup{} = saved, authority, :cleanup),
    do: NativeReleasedBranchDeletionCleanup.valid?(saved, authority, :cleanup)

  def valid?(%NativeBranchDeletionCollection{} = saved, authority, :collect),
    do: NativeBranchDeletionCollection.valid?(saved, authority, :collect)

  def valid?(_, _, _), do: false

  def matches?(%__MODULE__{request: request}, :continue, %BranchDeletionContinuation{} = proof),
    do: HeldBranchDeletionAction.matches?(proof, request, "continue")

  def matches?(%__MODULE__{request: request}, :cleanup, %BranchDeletionResolution{} = proof),
    do: HeldBranchDeletionAction.matches?(proof, request, "cleanup")

  def matches?(%NativeReleasedBranchDeletionContinuation{} = saved, :continue, proof),
    do: NativeReleasedBranchDeletionContinuation.matches?(saved, :continue, proof)

  def matches?(%NativeReleasedBranchDeletionCleanup{} = saved, :cleanup, proof),
    do: NativeReleasedBranchDeletionCleanup.matches?(saved, :cleanup, proof)

  def matches?(%NativeBranchDeletionCollection{} = saved, :collect, proof),
    do: NativeBranchDeletionCollection.matches?(saved, :collect, proof)

  def matches?(_, _, _), do: false

  def authority?(authority),
    do:
      Enum.all?([:collect, :continue, :cleanup], fn action ->
        saved = Map.fetch!(authority, field(action))
        saved == nil or valid?(saved, authority, action)
      end)

  def record?(
        %{branch: %{native_authority: %{delete_continuation: _, delete_cleanup: _} = authority}} =
          child
      ),
      do:
        Enum.all?([:collect, :continue, :cleanup], fn action ->
          record?(child, Map.fetch!(authority, field(action)), authority, action)
        end)

  def record?(_), do: false

  defp record?(_, nil, _, _), do: true

  defp record?(child, %__MODULE__{} = saved, authority, action) do
    valid?(saved, authority, action) and NativeBranchDeletionState.bound_record?(child, saved) and
      state?(child, saved.proof)
  end

  defp record?(child, %NativeReleasedBranchDeletionContinuation{}, _, :continue),
    do: NativeReleasedBranchDeletionContinuation.record?(child, &historical?/2)

  defp record?(child, %NativeReleasedBranchDeletionCleanup{}, _, :cleanup),
    do: NativeReleasedBranchDeletionCleanup.record?(child, &historical?/2)

  defp record?(child, %NativeBranchDeletionCollection{}, _, :collect),
    do: NativeBranchDeletionCollection.record?(child, &historical?/2)

  defp record?(_, _, _, _), do: false

  defp state?(child, nil),
    do: NativeBranchDeletion.eligible?(child) or historical?(child, :held)

  defp state?(child, _), do: NativeBranchDeletion.completed_state?(child)

  def historical?(child, :held),
    do:
      NativeBranchDeletion.completed_state?(child) and
        (acknowledged?(child.branch.native_authority) or
           match?(%{proof: %BranchDeletionResolution{}}, child.branch.native_authority.deletion))

  def historical?(child, :released) do
    authority = child.branch.native_authority

    NativeReleasedBranchDeletion.completed_state?(child) and
      (NativeReleasedBranchDeletionContinuation.acknowledged?(authority) or
         NativeReleasedBranchDeletionCleanup.acknowledged?(authority) or
         NativeBranchDeletion.acknowledged?(authority))
  end

  def acknowledged?(authority),
    do:
      match?(%__MODULE__{proof: %BranchDeletionContinuation{}}, authority.delete_continuation) or
        match?(%__MODULE__{proof: %BranchDeletionResolution{}}, authority.delete_cleanup) or
        NativeReleasedBranchDeletionContinuation.acknowledged?(authority) or
        NativeReleasedBranchDeletionCleanup.acknowledged?(authority)

  def preserved?(original, saved, version),
    do:
      Enum.all?([:collect, :continue, :cleanup], fn action ->
        slot = field(action)
        preserved_slot?(Map.fetch!(original, slot), Map.fetch!(saved, slot), version)
      end)

  defp preserved_slot?(nil, nil, _), do: true

  defp preserved_slot?(before, %NativeReleasedBranchDeletionContinuation{} = saved, version),
    do: NativeReleasedBranchDeletionContinuation.preserved?(before, saved, version)

  defp preserved_slot?(before, %NativeReleasedBranchDeletionCleanup{} = saved, version),
    do: NativeReleasedBranchDeletionCleanup.preserved?(before, saved, version)

  defp preserved_slot?(before, %NativeBranchDeletionCollection{} = saved, version),
    do: NativeBranchDeletionCollection.preserved?(before, saved, version)

  defp preserved_slot?(nil, %__MODULE__{version: version, proof: nil}, version), do: true

  defp preserved_slot?(%__MODULE__{proof: nil} = before, %__MODULE__{} = after_action, _),
    do: %{after_action | proof: nil} == before

  defp preserved_slot?(%__MODULE__{} = saved, saved, _), do: true
  defp preserved_slot?(_, _, _), do: false
  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)
end
