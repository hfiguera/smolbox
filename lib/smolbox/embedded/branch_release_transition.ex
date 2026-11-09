defmodule SmolBox.Embedded.BranchReleaseTransition do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, BranchOrigin, BranchRequest}
  alias SmolBox.Validation

  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  def from_wire(value), do: BranchCanonical.transition_from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value),
    do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value),
    do:
      BranchCanonical.transition_shape?(value) and
        change?(value["change"], value["previous"]) and transition?(value)

  defp change?(change, previous),
    do:
      BranchCanonical.keys?(change, :release_change) and BranchRequest.release?(change["request"]) and
        BranchOrigin.valid?(change["binding"], previous) and
        Enum.all?(~w(identity_sha256 boot_sha256 activation_token invariant_sha256), fn key ->
          Validation.digest?(change[key])
        end) and mode?(change)

  defp mode?(change),
    do:
      change["mode"] in ~w(initial explicit) and
        change["mode"] == "explicit" == change["binding"]["intent"]["child"]["hold"] and
        change["request"]["operation_id"] !=
          change["binding"]["intent"]["child"]["operation_id"]

  defp transition?(value) do
    old = value["previous"]["material"]
    next = value["receipt"]["material"]
    change = value["change"]

    BranchCanonical.root?(value["previous"]) and old["record_sha256"] != next["record_sha256"] and
      next["revision"] == 1 and next["operation_id"] == change["request"]["operation_id"] and
      next["request_sha256"] == change["request"]["request_sha256"] and
      next["chain_sha256"] ==
        BranchCanonical.digest([
          "smolbox-branch-child-release-v1",
          BranchCanonical.ordered(value["previous"], :receipt),
          BranchCanonical.ordered(change, :release_change),
          next["record_sha256"]
        ])
  end
end
