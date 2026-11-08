defmodule SmolBox.Embedded.BranchCanonical do
  @moduledoc false
  alias SmolBox.Embedded.Shape

  @transition_fields ~w(schema previous receipt change)

  def transition_from_wire(value, module) do
    if Shape.keys?(value, @transition_fields) and module.valid?(value) do
      fields = Map.new(value, fn {key, field} -> {String.to_existing_atom(key), field} end)
      {:ok, struct!(module, fields)}
    else
      :error
    end
  end

  def transition_wire(value),
    do: Map.new(Map.from_struct(value), fn {key, field} -> {Atom.to_string(key), field} end)

  def transition_shape?(value),
    do:
      Shape.keys?(value, @transition_fields) and value["schema"] === 1 and
        Shape.receipt?(value["previous"], 2) and Shape.receipt?(value["receipt"], 2) and
        origin(value["previous"]) == origin(value["receipt"])

  # Explicit serde struct order, including required nulls. These hashes check
  # history/correlation; they never grant SDK ownership or manager enrollment.
  @schemas %{
    receipt:
      {~w(target_id domain_generation name owner_token incarnation material_sha256 material),
       %{"material" => :material}},
    material: {~w(schema revision record_sha256 chain_sha256 operation_id request_sha256), %{}},
    resources: {~w(slots cpus memory_mb disk_gb), %{}},
    approval: {~w(id host_overhead_mb resources), %{"resources" => :resources}},
    child: {~w(operation_id name owner_token incarnation idle hold), %{}},
    creation_request:
      {~w(source child approval initial_release),
       %{
         "source" => :receipt,
         "child" => :child,
         "approval" => :approval,
         "initial_release" => :release_request
       }},
    initial_retirement: {~w(schema intent proof_sha256), %{"intent" => :intent}},
    unbooted_absence_request:
      {~w(disposal operation_id request_sha256 quiesced), %{"disposal" => :unbooted_disposal}},
    unbooted_disposal_candidate:
      {~w(schema creation publication preparation_sha256 proof_sha256),
       %{"creation" => :creation_request, "publication" => :publication}},
    unbooted_disposal_intent: {~w(operation_id request_sha256 quiesced), %{}},
    unbooted_disposal:
      {~w(schema completion creation request publication disposal_sha256 proof_sha256),
       %{
         "creation" => :creation_request,
         "request" => :unbooted_disposal_intent,
         "publication" => :publication
       }},
    release_request: {~w(operation_id request_sha256), %{}},
    plan:
      {~w(ordinary_child total_additional minimum_extra_memory_mb minimum_extra_disk_gb),
       %{"ordinary_child" => :resources, "total_additional" => :resources}},
    intent:
      {~w(source child approval plan request_sha256 source_pid epoch),
       %{
         "source" => :receipt,
         "child" => :child,
         "approval" => :approval,
         "plan" => :plan
       }},
    binding: {~w(intent generation raw_child_sha256), %{"intent" => :intent}},
    source_change:
      {~w(child_origin child platform previous_lineage lineage previous_growth_sha256 growth_sha256 previous_capture_sha256 capture_sha256 checkpoint_head),
       %{"child_origin" => :binding, "child" => :receipt}},
    release_change:
      {~w(request binding identity_sha256 boot_sha256 mode activation_token invariant_sha256),
       %{"request" => :release_request, "binding" => :binding}},
    publication:
      {~w(schema previous receipt change),
       %{"previous" => :receipt, "receipt" => :receipt, "change" => :source_change}},
    child_release:
      {~w(schema previous receipt change),
       %{"previous" => :receipt, "receipt" => :receipt, "change" => :release_change}},
    completion:
      {~w(schema publication child identity_sha256 held release),
       %{"publication" => :publication, "child" => :receipt, "release" => :child_release}},
    deletion_collection_grant:
      {~w(child operation_id request_sha256 completion_sha256 release_sha256 deletion_sha256),
       %{"child" => :receipt}},
    child_absence_request:
      {~w(completion child operation_id request_sha256 quiesced),
       %{"completion" => :completion, "child" => :receipt}}
  }

  def keys?(value, type), do: Shape.keys?(value, elem(Map.fetch!(@schemas, type), 0))

  def ordered(value, type) do
    {fields, children} = Map.fetch!(@schemas, type)

    pairs =
      for key <- fields, Map.has_key?(value, key) do
        field = Map.fetch!(value, key)

        {key,
         case Map.fetch(children, key) do
           {:ok, child} when field != nil -> ordered(field, child)
           _ -> field
         end}
      end

    %Jason.OrderedObject{values: pairs}
  end

  def digest(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  def origin(receipt), do: Map.delete(receipt, "material")

  def root?(receipt),
    do:
      Shape.receipt?(receipt, 2) and receipt["material"]["revision"] == 0 and
        receipt["material"]["chain_sha256"] ==
          digest(["smolbox-material-origin-v2", ordered(origin(receipt), :receipt)])
end
