defmodule SmolBox.Embedded.BranchCompletion do
  @moduledoc """
  Original completed native branch creation evidence for durable store adapters.

  The publication advances source material and binds an independently owned child;
  optional initial-release evidence records its automatic activation. Retain this
  value unchanged beside the immutable child root. Later held release, deletion,
  retirement and backing removal have separate evidence and lifetimes.
  This historical result alone proves neither current liveness nor SDK ownership.
  Inspect output omits receipt, process and ownership fields. Feature admission
  remains separately gated by the approved native descriptor and store support.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchPublication,
    BranchReleaseTransition,
    BranchRequest,
    Shape
  }

  alias SmolBox.Validation

  @enforce_keys [:schema, :publication, :child, :identity_sha256, :held]
  @derive {Inspect, only: [:schema, :held]}
  defstruct @enforce_keys ++ [release: nil]

  @type t :: %__MODULE__{}

  @doc false
  def from_wire(value) do
    if wire?(value) do
      {:ok,
       struct!(
         __MODULE__,
         Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
       )}
    else
      :error
    end
  end

  @doc false
  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and wire?(to_wire(value))

  def valid?(_), do: false

  @doc false
  def to_wire(%__MODULE__{} = value), do: BranchCanonical.optional_release_fields(value)

  @doc false
  def wire?(value) when is_map(value),
    do:
      Shape.keys?(Map.delete(value, "release"), ~w(schema publication child identity_sha256 held)) and
        value["schema"] === 1 and Validation.digest?(value["identity_sha256"]) and
        BranchPublication.valid?(value["publication"]) and release?(value) and bounded?(value)

  def wire?(_), do: false

  @doc false
  def matches?(value, request) do
    wire?(value) and BranchRequest.valid?(request) and request_matches?(value, request)
  end

  defp request_matches?(value, request) do
    intent = value["publication"]["change"]["child_origin"]["intent"]

    value["publication"]["previous"] == request["source"] and
      intent["child"] == request["child"] and intent["approval"] == request["approval"] and
      value["held"] == request["child"]["hold"] and
      (value["held"] or
         (value["release"]["change"]["mode"] == "initial" and
            value["release"]["change"]["request"] == request["initial_release"]))
  end

  defp release?(%{"release" => release} = value),
    do:
      value["held"] == false and BranchReleaseTransition.valid?(release) and
        release["previous"] == value["publication"]["change"]["child"] and
        release["receipt"] == value["child"] and
        release["change"]["identity_sha256"] == value["identity_sha256"] and
        release["change"]["binding"] == value["publication"]["change"]["child_origin"]

  defp release?(value),
    do:
      value["held"] == true and
        value["publication"]["change"]["child_origin"]["intent"]["child"]["hold"] == true and
        value["child"] == value["publication"]["change"]["child"]

  defp bounded?(value) do
    case Jason.encode(value) do
      {:ok, bytes} -> byte_size(bytes) <= 65_536
      _ -> false
    end
  end
end
