defmodule SmolBox.Embedded.UnbootedBranchChildAbsence do
  @moduledoc """
  Fresh namespace-absence correlation under original unbooted disposal authority.

  The engine requires the exact original archive/runtime/domain/ledger and child
  epoch quiescence, then checks the SDK row, creation reservation and original
  directory before and after issuing evidence. The source may remain running.
  A stored disposal alone proves no current absence. This historical observation
  is neither boot completion nor disposal, dependency retirement or backing release.
  """
  alias SmolBox.Embedded.{BranchCanonical, Shape, UnbootedBranchDisposal}
  alias SmolBox.Validation
  @enforce_keys [:schema, :request, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
  @maximum 68 * 1024

  def request?(request),
    do:
      Shape.keys?(request, ~w(disposal operation_id request_sha256 quiesced)) and
        UnbootedBranchDisposal.valid?(request["disposal"]) and not is_struct(request["disposal"]) and
        Shape.id?(request["operation_id"]) and request["quiesced"] == true and
        request["operation_id"] not in [
          get_in(request, ~w(disposal creation child operation_id)),
          get_in(request, ~w(disposal creation initial_release operation_id)),
          get_in(request, ~w(disposal request operation_id))
        ] and
        request["request_sha256"] == request_digest(request) and
        byte_size(Jason.encode!(request)) <= @maximum

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-unbooted-branch-child-absence-request-v1",
        BranchCanonical.ordered(request["disposal"], :unbooted_disposal),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value), do: BranchCanonical.from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value),
    do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      Shape.keys?(value, ~w(schema request proof_sha256)) and value["schema"] === 1 and
        request?(value["request"]) and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= @maximum

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-unbooted-branch-child-absence-v1",
        value["schema"],
        BranchCanonical.ordered(value["request"], :unbooted_absence_request)
      ])

  def matches?(%__MODULE__{} = value, request), do: matches?(to_wire(value), request)

  def matches?(value, request),
    do: request?(request) and valid?(value) and value["request"] == request

  def approval(request), do: get_in(request, ~w(disposal creation approval))
  def platform(request), do: get_in(request, ~w(disposal publication change platform))

  def epoch(request),
    do: get_in(request, ~w(disposal publication change child_origin intent epoch))
end
