defmodule SmolBox.Embedded.BranchBackingRelease do
  @moduledoc """
  Acknowledgement of an original native branch's backing accounting release.

  The shared engine retains the original completion, verifies source and child
  absence, and records the explicit host backing-removal confirmation. Stores
  must save the exact request before dispatch and retain their charge until a
  matching acknowledgement commits atomically with the branch's closed state.
  Expected heads must match durable tombstones; this proof does not establish
  their historical existence or authorize filesystem or SDK deletion.
  Inspect output omits receipt and ownership fields.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchPublication,
    BranchRequest,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [
    :schema,
    :publication,
    :operation_id,
    :request_sha256,
    :native_bytes,
    :proof_sha256
  ]
  @derive {Inspect, only: [:schema, :native_bytes]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: 1,
          publication: map(),
          operation_id: String.t(),
          request_sha256: String.t(),
          native_bytes: pos_integer(),
          proof_sha256: String.t()
        }
  @request_maximum 80 * 1024
  @proof_maximum 68 * 1024

  def request?(request),
    do:
      Shape.keys?(
        request,
        ~w(completion source child operation_id request_sha256 quiesced backing_removed)
      ) and
        BranchCompletion.wire?(request["completion"]) and
        BranchCanonical.current_head?(
          request["source"],
          get_in(request, ~w(completion publication receipt))
        ) and
        BranchCanonical.current_head?(request["child"], get_in(request, ~w(completion child))) and
        request["quiesced"] == true and request["backing_removed"] == true and
        request_identity?(request) and
        request["request_sha256"] == request_digest(request) and
        bounded?(request, @request_maximum)

  defp request_identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        request["operation_id"] !=
          get_in(request, ~w(completion release change request operation_id))

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-branch-backing-request-v1",
        BranchCanonical.ordered(request["completion"], :completion),
        BranchCanonical.ordered(request["source"], :receipt),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"],
        request["backing_removed"]
      ])

  def from_wire(value) do
    if Shape.keys?(
         value,
         ~w(schema publication operation_id request_sha256 native_bytes proof_sha256)
       ) and valid?(value),
       do:
         {:ok,
          struct!(
            __MODULE__,
            Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
          )},
       else: :error
  end

  def to_wire(%__MODULE__{} = proof),
    do: Map.new(Map.from_struct(proof), fn {key, value} -> {Atom.to_string(key), value} end)

  def valid?(%__MODULE__{} = proof),
    do: Validation.struct_shape?(proof, __MODULE__) and valid?(to_wire(proof))

  def valid?(proof),
    do:
      Shape.keys?(
        proof,
        ~w(schema publication operation_id request_sha256 native_bytes proof_sha256)
      ) and
        proof["schema"] === 1 and BranchPublication.valid?(proof["publication"]) and
        BranchRequest.release?(Map.take(proof, ~w(operation_id request_sha256))) and
        proof["native_bytes"] === native_bytes(proof["publication"]) and
        proof["proof_sha256"] ==
          BranchCanonical.digest([
            "smolbox-branch-backing-release-v1",
            1,
            BranchCanonical.ordered(proof["publication"], :publication),
            proof["operation_id"],
            proof["request_sha256"],
            proof["native_bytes"]
          ]) and bounded?(proof, @proof_maximum)

  defp native_bytes(publication) do
    plan = get_in(publication, ~w(change child_origin intent plan))
    (plan["ordinary_child"]["disk_gb"] + plan["minimum_extra_disk_gb"]) * 1_073_741_824
  end

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and
        proof["publication"] == request["completion"]["publication"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"]

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))

  defp bounded?(value, maximum), do: byte_size(Jason.encode!(value)) <= maximum
end
