defmodule SmolBox.Embedded.BranchDeletionCollection do
  @moduledoc """
  Historical collection of the retained original child of an uncertain deletion.

  This proof grants no readiness, stopped-row, deletion, absence or capacity-release
  authority. Final SDK deletion requires its separate accepted continuation.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchReleaseTransition,
    BranchRequest,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys ~w(schema child operation_id request_sha256 completion_sha256 deletion_sha256 collection_sha256 proof_sha256)a
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys ++ [release_sha256: nil]
  @type t :: %__MODULE__{}
  @request_keys ~w(completion child operation_id request_sha256 quiesced)
  @proof_keys Enum.map(@enforce_keys, &Atom.to_string/1)

  def request?(request),
    do:
      optional_keys?(request, @request_keys, "release") and
        BranchCompletion.wire?(request["completion"]) and Shape.receipt?(request["child"], 2) and
        request["quiesced"] == true and release_bound?(request) and
        BranchRequest.release?(Map.take(request, ~w(operation_id request_sha256))) and
        request["operation_id"] !=
          get_in(
            request,
            ~w(completion publication change child_origin intent child operation_id)
          ) and
        request["request_sha256"] == request_digest(request) and
        byte_size(Jason.encode!(request)) <= 132 * 1024

  defp release_bound?(%{"release" => release} = request) when not is_nil(release),
    do:
      BranchReleaseTransition.valid?(release) and
        release["previous"] == get_in(request, ~w(completion publication change child)) and
        release["change"]["binding"] ==
          get_in(request, ~w(completion publication change child_origin)) and
        release["change"]["identity_sha256"] == request["completion"]["identity_sha256"] and
        request["child"] == release["receipt"] and
        (request["completion"]["held"] or request["completion"]["release"] == release) and
        request["operation_id"] != get_in(release, ~w(change request operation_id))

  defp release_bound?(request),
    do: request["completion"]["held"] and request["child"] == request["completion"]["child"]

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-original-child-delete-collection-request-v1",
        BranchCanonical.ordered(request["completion"], :completion),
        ordered_release(request["release"]),
        BranchCanonical.ordered(request["child"], :receipt),
        request["operation_id"],
        request["quiesced"]
      ])

  defp ordered_release(nil), do: nil
  defp ordered_release(release), do: BranchCanonical.ordered(release, :child_release)

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

  def to_wire(%__MODULE__{} = proof),
    do:
      proof
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

  def valid?(%__MODULE__{} = proof),
    do: Validation.struct_shape?(proof, __MODULE__) and valid?(to_wire(proof))

  def valid?(value),
    do:
      optional_keys?(value, @proof_keys, "release_sha256") and proof_identity?(value) and
        proof_fields?(value) and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= 4096

  defp proof_identity?(value),
    do:
      value["schema"] === 1 and Shape.receipt?(value["child"], 2) and
        value["child"]["material"]["revision"] ==
          if(value["release_sha256"] == nil, do: 0, else: 1)

  defp proof_fields?(value),
    do:
      BranchRequest.release?(Map.take(value, ~w(operation_id request_sha256))) and
        Enum.all?(
          ~w(completion_sha256 deletion_sha256 collection_sha256),
          &Validation.digest?(value[&1])
        ) and
        (value["release_sha256"] == nil or Validation.digest?(value["release_sha256"]))

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-original-child-delete-collection-proof-v1",
        value["schema"],
        value
        |> Map.take(
          ~w(child operation_id request_sha256 completion_sha256 release_sha256 deletion_sha256)
        )
        |> Enum.reject(fn {_key, field} -> is_nil(field) end)
        |> Map.new()
        |> BranchCanonical.ordered(:deletion_collection_grant),
        value["collection_sha256"]
      ])

  def matches?(%__MODULE__{} = proof, request), do: matches?(to_wire(proof), request)

  def matches?(proof, request),
    do:
      valid?(proof) and request?(request) and proof["child"] == request["child"] and
        proof["operation_id"] == request["operation_id"] and
        proof["request_sha256"] == request["request_sha256"] and
        proof["completion_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["completion"], :completion)) and
        proof["release_sha256"] == release_digest(request["release"])

  defp release_digest(nil), do: nil
  defp release_digest(release), do: BranchCanonical.digest(ordered_release(release))

  defp optional_keys?(value, keys, optional),
    do: Shape.keys?(value, keys) or Shape.keys?(value, keys ++ [optional])

  def platform(request), do: get_in(request, ~w(completion publication change platform))

  def approval(request),
    do: get_in(request, ~w(completion publication change child_origin intent approval))
end
