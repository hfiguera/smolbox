defmodule SmolBox.Embedded.PartialBranchCollection do
  @moduledoc """
  Collection of the original enrolled child before branch readiness/handoff.

  This acknowledgement grants no SDK deletion, namespace absence, initialized
  readiness, source cleanup or reservation release.
  """
  alias SmolBox.Embedded.{BranchCanonical, BranchRequest, Shape}
  alias SmolBox.Validation

  @enforce_keys ~w(schema creation_sha256 publication_sha256 operation_id request_sha256 boot_sha256 collection_sha256 proof_sha256)a
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
  @keys Enum.map(@enforce_keys, &Atom.to_string/1)

  def request?(request),
    do:
      Shape.keys?(request, ~w(creation operation_id request_sha256 quiesced)) and
        BranchRequest.valid?(request["creation"]) and
        is_map(get_in(request, ~w(creation source material))) and
        action?(request) and
        request["request_sha256"] == request_digest(request) and
        byte_size(Jason.encode!(request["creation"])) <= 16 * 1024 and
        byte_size(Jason.encode!(request)) <= 20 * 1024

  defp action?(request),
    do:
      request["quiesced"] == true and
        BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] != get_in(request, ~w(creation child operation_id)) and
        request["operation_id"] != get_in(request, ~w(creation initial_release operation_id))

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-collection-request-v1",
        BranchCanonical.ordered(request["creation"], :creation_request),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(__MODULE__, Map.new(value, fn {k, v} -> {String.to_existing_atom(k), v} end))},
      else: :error
  end

  def to_wire(%__MODULE__{} = proof),
    do: Map.new(Map.from_struct(proof), fn {k, v} -> {Atom.to_string(k), v} end)

  def valid?(%__MODULE__{} = proof),
    do: Validation.struct_shape?(proof, __MODULE__) and valid?(to_wire(proof))

  def valid?(value),
    do:
      Shape.keys?(value, @keys) and value["schema"] === 1 and
        Shape.id?(value["operation_id"]) and
        Enum.all?(
          ~w(creation_sha256 publication_sha256 request_sha256 boot_sha256 collection_sha256),
          &Validation.digest?(value[&1])
        ) and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 4096

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-partial-branch-collection-proof-v1",
        value["schema"],
        value["creation_sha256"],
        value["publication_sha256"],
        value["operation_id"],
        value["request_sha256"],
        value["boot_sha256"],
        value["collection_sha256"]
      ])

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"] and
        proof["creation_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["creation"], :creation_request))

  def approval(request), do: get_in(request, ~w(creation approval))
end
