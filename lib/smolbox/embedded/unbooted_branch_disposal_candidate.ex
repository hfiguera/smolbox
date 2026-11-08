defmodule SmolBox.Embedded.UnbootedBranchDisposalCandidate do
  @moduledoc """
  Read-only correlation for an original published child that never entered boot.

  This transient response selects a possible disposal path. It grants no SDK
  ownership, child readiness, absence, charge release or replay permission.
  Disposal independently rechecks its accepted request and original context.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    BranchRequest,
    NativeCollectedBranchPublication,
    NativeUnbootedBranchDisposal,
    Shape
  }

  alias SmolBox.Validation
  @enforce_keys [:schema, :creation, :publication, :preparation_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def request?(creation),
    do: BranchRequest.valid?(creation) and byte_size(Jason.encode!(creation)) <= 16 * 1024

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(
           __MODULE__,
           Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
         )},
      else: :error
  end

  def to_wire(%__MODULE__{} = value),
    do: Map.new(Map.from_struct(value), fn {key, field} -> {Atom.to_string(key), field} end)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      Shape.keys?(value, ~w(schema creation publication preparation_sha256 proof_sha256)) and
        value["schema"] === 1 and request?(value["creation"]) and
        BranchPublication.valid?(value["publication"]) and
        Map.take(
          get_in(value, ~w(publication change child_origin intent)),
          ~w(source child approval)
        ) ==
          Map.take(value["creation"], ~w(source child approval)) and
        Validation.digest?(value["preparation_sha256"]) and
        value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 32 * 1024

  # Selection evidence is transient and requires the original pinned helper and
  # still-locked source/child pair. It never completes or disposes the child.
  def bound?(%__MODULE__{} = candidate, parent, child, epoch, platform) do
    with true <- NativeUnbootedBranchDisposal.pending?(parent, child),
         true <- child.branch.native_authority.disposal == nil,
         true <- matches?(candidate, child.branch.native_authority.request) do
      intent = get_in(candidate.publication, ~w(change child_origin intent))

      NativeCollectedBranchPublication.publication_pending?(parent, child, candidate.publication) and
        intent["epoch"] == epoch and candidate.publication["change"]["platform"] == platform and
        intent["source_pid"] == child.branch.source_machine.backend_identity.pid_identity and
        NativeUnbootedBranchDisposal.plan?(candidate, child.spec.profile)
    else
      _ -> false
    end
  end

  def bound?(_, _, _, _, _), do: false

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-original-unbooted-disposal-candidate-v1",
        value["schema"],
        BranchCanonical.ordered(value["creation"], :creation_request),
        BranchCanonical.ordered(value["publication"], :publication),
        value["preparation_sha256"]
      ])

  def matches?(%__MODULE__{} = value, creation), do: matches?(to_wire(value), creation)

  def matches?(value, creation),
    do: request?(creation) and valid?(value) and value["creation"] == creation
end
