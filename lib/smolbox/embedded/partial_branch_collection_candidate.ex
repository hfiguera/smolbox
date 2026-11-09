defmodule SmolBox.Embedded.PartialBranchCollectionCandidate do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, PartialBranchCollection, Shape}
  alias SmolBox.Validation

  @enforce_keys ~w(schema creation_sha256 operation_id request_sha256 epoch platform)a
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys
  @keys Enum.map(@enforce_keys, &Atom.to_string/1)

  def from_wire(value) do
    if valid?(value) and not is_struct(value),
      do:
        {:ok,
         struct!(__MODULE__, Map.new(value, fn {k, v} -> {String.to_existing_atom(k), v} end))},
      else: :error
  end

  def to_wire(%__MODULE__{} = value),
    do: Map.new(Map.from_struct(value), fn {k, v} -> {Atom.to_string(k), v} end)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      Shape.keys?(value, @keys) and value["schema"] === 1 and
        Validation.digest?(value["creation_sha256"]) and Shape.id?(value["operation_id"]) and
        Validation.digest?(value["request_sha256"]) and Shape.hex?(value["epoch"], 32) and
        value["platform"] in ~w(linux macos) and byte_size(Jason.encode!(value)) <= 4096

  def matches?(%__MODULE__{} = value, request), do: matches?(to_wire(value), request)

  def matches?(value, request),
    do:
      valid?(value) and PartialBranchCollection.request?(request) and
        value["operation_id"] == request["operation_id"] and
        value["request_sha256"] == request["request_sha256"] and
        value["creation_sha256"] ==
          BranchCanonical.digest(BranchCanonical.ordered(request["creation"], :creation_request))
end
