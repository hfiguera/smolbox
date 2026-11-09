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
    Shape
  }

  alias SmolBox.Validation
  @enforce_keys [:schema, :creation, :publication, :preparation_sha256, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def request?(creation),
    do: BranchRequest.valid?(creation) and byte_size(Jason.encode!(creation)) <= 16 * 1024

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value),
    do: BranchCanonical.wire_fields(value)

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
