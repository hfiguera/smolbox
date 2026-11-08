defmodule SmolBox.Embedded.NativeReleasedBranchDeletion do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    NativeBranchDeletionState,
    NativeBranchRelease,
    ReleasedBranchDeletionResolution
  }

  alias SmolBox.Validation
  @enforce_keys [:version, :delete_version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  def release(%{release: %NativeBranchRelease{transition: %BranchReleaseTransition{} = proof}}),
    do: {:ok, BranchReleaseTransition.to_wire(proof)}

  def release(%{release: nil, completion: %BranchCompletion{held: false, release: proof}})
      when is_map(proof),
      do: {:ok, proof}

  def release(_), do: :error

  def eligible?(%{branch: %{state: state, native_authority: authority}} = child) do
    NativeBranchDeletionState.pending?(child) and state in [:ready, :released] and
      match?({:ok, _}, release(authority))
  end

  def eligible?(_), do: false

  @resolution {ReleasedBranchDeletionResolution, "resolve-delete-",
               "smolbox-native-released-delete-resolution-v1"}

  def intent(authority, version, delete_version, receipt),
    do: request(authority, version, delete_version, receipt, @resolution)

  def request(authority, version, delete_version, receipt, {wire, prefix, domain}) do
    {:ok, release} = release(authority)
    completion = BranchCompletion.to_wire(authority.completion)

    digest =
      BranchCanonical.digest([
        domain,
        authority.fingerprint,
        version,
        delete_version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(completion, :completion),
        BranchCanonical.ordered(release, :child_release)
      ])

    request = %{
      "completion" => completion,
      "release" => release,
      "child" => receipt,
      "operation_id" => prefix <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", wire.request_digest(request))
  end

  def valid?(%__MODULE__{} = saved, authority),
    do:
      valid_request?(saved, authority, __MODULE__, @resolution) and
        (saved.proof == nil or matches?(saved, saved.proof))

  def valid?(_, _), do: false

  def valid_request?(saved, authority, module, {wire, _, _} = operation) do
    Validation.struct_shape?(saved, module) and
      version?(saved.version) and version?(saved.delete_version) and
      saved.delete_version <= saved.version and match?({:ok, _}, release(authority)) and
      wire.request?(saved.request) and
      saved.request ==
        request(authority, saved.version, saved.delete_version, saved.request["child"], operation)
  end

  def matches?(%__MODULE__{request: request}, %ReleasedBranchDeletionResolution{} = proof),
    do: ReleasedBranchDeletionResolution.matches?(proof, request)

  def matches?(_, _), do: false

  def record?(
        %{branch: %{native_authority: %{deletion: %__MODULE__{} = saved} = authority}} = child,
        historical?
      ),
      do: valid?(saved, authority) and bound_record?(child, saved, historical?)

  def record?(_, _), do: false

  def bound_record?(child, saved, historical?) do
    NativeBranchDeletionState.bound_record?(child, saved) and
      if(saved.proof == nil,
        do: eligible?(child) or historical?.(child, :released),
        else: completed_state?(child)
      )
  end

  def completed_state?(child),
    do: NativeBranchDeletionState.completed?(child, [:ready, :released, :retired, :closed])

  def preserved?(before, after_record, version),
    do: NativeBranchDeletionState.preserves?(before, after_record, version, __MODULE__)

  defp version?(value), do: Validation.integer?(value, 1, 9_007_199_254_740_991)
end
