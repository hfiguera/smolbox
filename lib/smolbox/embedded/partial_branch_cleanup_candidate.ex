defmodule SmolBox.Embedded.PartialBranchCleanupCandidate do
  @moduledoc """
  Positive original residual eligibility before a fresh cleanup action.

  This is neither disposal nor removal proof. The original native control must
  recheck all facts after public acceptance; this value releases no capacity and
  authorizes no SDK entry, initialization, source liveness or ownership adoption.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    PartialBranchDisposal,
    PartialBranchDisposalContext,
    Shape
  }

  alias SmolBox.Validation
  @enforce_keys [:schema, :request, :publication, :disposal_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys ++ [release: nil]
  @type t :: %__MODULE__{}

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value) when is_map(value),
    do:
      Shape.keys?(
        Map.delete(value, "release"),
        ~w(schema request publication disposal_sha256 proof_sha256)
      ) and
        value["schema"] === 1 and PartialBranchDisposal.request?(value["request"]) and
        BranchPublication.valid?(value["publication"]) and
        PartialBranchDisposalContext.valid?(value) and
        Validation.digest?(value["disposal_sha256"]) and
        value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 48 * 1024

  def valid?(_), do: false

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(__MODULE__, Map.new(value, fn {k, v} -> {String.to_existing_atom(k), v} end))},
      else: :error
  end

  def to_wire(%__MODULE__{} = value) do
    wire = Map.new(Map.from_struct(value), fn {k, v} -> {Atom.to_string(k), v} end)
    if value.release == nil, do: Map.delete(wire, "release"), else: wire
  end

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-cleanup-candidate-v1",
        value["schema"],
        BranchCanonical.ordered(value["request"], :partial_disposal_request),
        BranchCanonical.ordered(value["publication"], :publication),
        if(value["release"] != nil,
          do: BranchCanonical.ordered(value["release"], :child_release)
        ),
        value["disposal_sha256"]
      ])

  def matches?(%__MODULE__{} = value, request), do: matches?(to_wire(value), request)

  def matches?(value, request),
    do: valid?(value) and PartialBranchDisposal.request?(request) and value["request"] == request
end
