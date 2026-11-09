defmodule SmolBox.Embedded.BranchPublication do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, BranchOrigin, Shape}
  alias SmolBox.Validation

  @hashes ~w(previous_growth_sha256 growth_sha256 previous_capture_sha256 capture_sha256)
  @enforce_keys [:schema, :previous, :receipt, :change]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  def from_wire(value), do: BranchCanonical.transition_from_wire(value, __MODULE__)

  def to_wire(%__MODULE__{} = value),
    do: BranchCanonical.wire_fields(value)

  def valid?(%__MODULE__{} = value),
    do: Validation.struct_shape?(value, __MODULE__) and valid?(to_wire(value))

  def valid?(value) do
    BranchCanonical.transition_shape?(value) and
      change?(value["change"]) and
      value["previous"] == value["change"]["child_origin"]["intent"]["source"] and
      transition?(value)
  end

  defp change?(change),
    do:
      BranchCanonical.keys?(change, :source_change) and
        BranchOrigin.valid?(change["child_origin"], change["child"]) and
        BranchCanonical.root?(change["child"]) and
        Enum.all?(@hashes, &Validation.digest?(change[&1])) and
        Shape.optional?(change["checkpoint_head"], &Shape.hex?(&1, 32)) and
        Shape.optional?(change["previous_lineage"], &u64?/1) and
        Shape.optional?(change["lineage"], &u64?/1) and lineage?(change)

  defp lineage?(%{"platform" => "linux"} = change),
    do: change["lineage"] == Enum.at(change["child_origin"]["intent"]["source_pid"], 1)

  defp lineage?(%{"platform" => "macos"} = change),
    do: change["lineage"] == change["previous_lineage"]

  defp lineage?(_), do: false

  defp transition?(value) do
    old = value["previous"]["material"]
    next = value["receipt"]["material"]
    change = value["change"]
    intent = change["child_origin"]["intent"]

    (old["revision"] != 0 or BranchCanonical.root?(value["previous"])) and
      unchanged_lineage?(change, old, next) and next["revision"] == old["revision"] + 1 and
      next["operation_id"] == intent["child"]["operation_id"] and
      next["request_sha256"] == intent["request_sha256"] and
      next["chain_sha256"] ==
        BranchCanonical.digest([
          "smolbox-branch-source-transition-v1",
          BranchCanonical.ordered(change, :source_change),
          next["record_sha256"]
        ])
  end

  defp unchanged_lineage?(change, old, next),
    do:
      change["lineage"] != change["previous_lineage"] or
        (change["growth_sha256"] == change["previous_growth_sha256"] and
           change["capture_sha256"] == change["previous_capture_sha256"] and
           next["record_sha256"] == old["record_sha256"])

  defp u64?(value), do: Validation.integer?(value, 1, 18_446_744_073_709_551_615)
end
