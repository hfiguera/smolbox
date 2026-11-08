defmodule SmolBox.Embedded.PartialBranchDisposalCleanupUnneeded do
  @moduledoc """
  Original terminal disposal made an accepted cleanup unnecessary. This is no
  residual-removal, SDK-entry, live-source or dependency/backing release proof.
  Both original terminal provenances remain intact.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    PartialBranchDisposal,
    PartialBranchDisposalCleanup,
    Shape
  }

  alias SmolBox.Validation
  @enforce_keys [:schema, :request, :disposal, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(__MODULE__, Map.new(value, fn {k, v} -> {String.to_existing_atom(k), v} end))},
      else: :error
  end

  def to_wire(%__MODULE__{} = proof),
    do: Map.new(Map.from_struct(proof), fn {k, v} -> {Atom.to_string(k), v} end)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value) when is_map(value),
    do:
      Shape.keys?(value, ~w(schema request disposal proof_sha256)) and
        PartialBranchDisposalCleanup.request?(value["request"]) and context?(value) and
        proof_fields?(value)

  def valid?(_), do: false

  defp context?(value),
    do:
      not is_struct(value["disposal"]) and PartialBranchDisposal.valid?(value["disposal"]) and
        value["disposal"]["request"] == value["request"]["disposal_request"] and
        get_in(value, ~w(disposal release change request operation_id)) !=
          value["request"]["operation_id"]

  defp proof_fields?(value),
    do:
      value["schema"] === 1 and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 80 * 1024

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-disposal-cleanup-unneeded-v1",
        value["schema"],
        BranchCanonical.ordered(value["request"], :partial_cleanup_request),
        BranchCanonical.ordered(value["disposal"], :partial_disposal)
      ])

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and PartialBranchDisposalCleanup.request?(request) and
        proof["request"] == request
end
