defmodule SmolBox.Embedded.ReleasedBranchDeletionResolution do
  @moduledoc """
  Request-bound positive absence after an original released-child deletion.

  The shared engine requires retained original completion and deletion context,
  a returned worker, original collection and SDK row/reservation/directory absence.
  It neither invokes SDK deletion nor removes files. Stores must additionally bind
  the request to the saved management intent/version before resolving uncertainty.
  Dependency retirement and backing release require their separate proofs.
  Inspect output omits native receipt and request identity fields.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    BranchRequest,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [
    :schema,
    :child,
    :operation_id,
    :request_sha256,
    :completion_sha256,
    :release_sha256,
    :deletion_sha256,
    :proof_sha256
  ]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: 1,
          child: map(),
          operation_id: String.t(),
          request_sha256: String.t(),
          completion_sha256: String.t(),
          release_sha256: String.t(),
          deletion_sha256: String.t(),
          proof_sha256: String.t()
        }
  @request_maximum 132 * 1024
  @proof_maximum 4096

  def request?(request),
    do:
      Shape.keys?(request, ~w(completion release child operation_id request_sha256 quiesced)) and
        BranchCompletion.wire?(request["completion"]) and
        BranchReleaseTransition.valid?(request["release"]) and
        Shape.receipt?(request["child"], 2) and request["quiesced"] == true and
        release_bound?(request) and
        request_identity?(request) and byte_size(Jason.encode!(request)) <= @request_maximum

  defp release_bound?(request),
    do:
      request["release"]["previous"] == get_in(request, ~w(completion publication change child)) and
        request["release"]["change"]["binding"] ==
          get_in(request, ~w(completion publication change child_origin)) and
        request["release"]["change"]["identity_sha256"] ==
          request["completion"]["identity_sha256"] and
        request["child"] == request["release"]["receipt"] and
        (request["completion"]["held"] == true or
           request["completion"]["release"] == request["release"])

  defp request_identity?(request),
    do:
      BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] != get_in(request, ~w(release change request operation_id)) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        request["request_sha256"] == request_digest(request)

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-released-child-delete-request-v1",
        BranchCanonical.ordered(request["completion"], :completion),
        BranchCanonical.ordered(request["release"], :child_release),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"]
      ])

  def from_wire(value) do
    if Shape.keys?(
         value,
         ~w(schema child operation_id request_sha256 completion_sha256 release_sha256 deletion_sha256 proof_sha256)
       ) and valid?(value),
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
      Shape.keys?(
        value,
        ~w(schema child operation_id request_sha256 completion_sha256 release_sha256 deletion_sha256 proof_sha256)
      ) and
        value["schema"] === 1 and Shape.receipt?(value["child"], 2) and
        value["child"]["material"]["revision"] == 1 and
        BranchRequest.release?(Map.take(value, ~w(operation_id request_sha256))) and
        Enum.all?(
          ~w(completion_sha256 release_sha256 deletion_sha256),
          &Validation.digest?(value[&1])
        ) and
        value["proof_sha256"] ==
          BranchCanonical.digest([
            "smolbox-released-child-delete-resolution-v1",
            1,
            BranchCanonical.ordered(value["child"], :receipt),
            value["operation_id"],
            value["request_sha256"],
            value["completion_sha256"],
            value["release_sha256"],
            value["deletion_sha256"]
          ]) and byte_size(Jason.encode!(value)) <= @proof_maximum

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and proof["child"] == request["child"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"] and
        proof["completion_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)) and
        proof["release_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["release"], :child_release))

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))
end
