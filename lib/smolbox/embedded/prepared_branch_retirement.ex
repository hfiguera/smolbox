defmodule SmolBox.Embedded.PreparedBranchRetirement do
  @moduledoc """
  Correlated retirement of a protected declaration before SDK entry.

  It attests no child disposal, activation or entered backing release. The outer
  request binds host intent, including an unused initial-release choice; only the
  inner native declaration is retired. Hashes alone confer no SDK ownership.
  """
  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchOrigin,
    BranchRequest,
    NativePreparedBranchRetirement,
    Shape
  }

  alias SmolBox.{Profile, Validation}
  @enforce_keys [:schema, :request_sha256, :retirement, :proof_sha256]
  @derive {Inspect, only: [:schema]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema: 1,
          request_sha256: String.t(),
          retirement: map(),
          proof_sha256: String.t()
        }
  @maximum 16 * 1024

  def request?(request),
    do:
      Shape.keys?(request, ~w(creation request_sha256 quiesced)) and
        BranchRequest.valid?(request["creation"]) and request["quiesced"] == true and
        request["request_sha256"] == request_digest(request) and
        byte_size(Jason.encode!(request)) <= @maximum

  def request_digest(request),
    do:
      BranchCanonical.digest([
        "smolbox-prepared-branch-retirement-request-v1",
        BranchCanonical.ordered(request["creation"], :creation_request),
        request["quiesced"]
      ])

  def from_wire(value) do
    if Shape.keys?(value, ~w(schema request_sha256 retirement proof_sha256)) and valid?(value),
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
      Shape.keys?(value, ~w(schema request_sha256 retirement proof_sha256)) and
        value["schema"] === 1 and Validation.digest?(value["request_sha256"]) and
        retirement?(value["retirement"]) and value["proof_sha256"] == proof_digest(value) and
        byte_size(Jason.encode!(value)) <= @maximum

  def proof_digest(value),
    do:
      BranchCanonical.digest([
        "smolbox-prepared-branch-retirement-proof-v1",
        value["schema"],
        value["request_sha256"],
        BranchCanonical.ordered(value["retirement"], :initial_retirement)
      ])

  defp retirement?(value),
    do:
      Shape.keys?(value, ~w(schema intent proof_sha256)) and value["schema"] === 1 and
        BranchOrigin.intent?(value["intent"]) and
        value["proof_sha256"] ==
          BranchCanonical.digest([
            "smolbox-initial-branch-retirement-v1",
            BranchCanonical.ordered(value["intent"], :intent)
          ])

  def matches?(proof, request),
    do: request?(request) and valid?(proof) and bound?(wire(proof), request)

  defp wire(%__MODULE__{} = value), do: to_wire(value)
  defp wire(value), do: value

  defp bound?(proof, request),
    do:
      proof["request_sha256"] == request["request_sha256"] and
        Map.take(proof["retirement"]["intent"], ~w(source child approval)) ==
          Map.take(request["creation"], ~w(source child approval))

  def approval(request), do: get_in(request, ~w(creation approval))

  @doc false
  def saved_valid?(%{__struct__: NativePreparedBranchRetirement, proof: %__MODULE__{}} = saved),
    do:
      Shape.keys?(saved, [:__struct__, :version, :request, :proof]) and
        Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
        matches?(saved.proof, saved.request)

  def saved_valid?(_), do: false

  @doc false
  def saved_plan?(saved, profile),
    do:
      saved.proof.retirement["intent"]["plan"]["ordinary_child"] ==
        Map.new(Profile.resources(profile), fn {key, value} -> {Atom.to_string(key), value} end)

  @doc false
  def saved_source?(record, id, %{__struct__: NativePreparedBranchRetirement} = saved) do
    receipt = saved.request["creation"]["source"]
    intent = saved.proof.retirement["intent"]
    root = record.created_machine.backend_identity.receipt
    profile = record.spec.profile

    saved_valid?(saved) and Validation.identifier?(id) and record.branch_children[id] == true and
      id != record.active_branch and saved.request["creation"]["child"]["operation_id"] == id and
      Map.delete(receipt, "material") == Map.delete(root, "material") and
      Shape.receipt?(root, 2) and
      intent["approval"]["host_overhead_mb"] == profile.host_overhead_mb and
      saved_plan?(saved, profile)
  end

  def saved_source?(_, _, _), do: false

  @doc false
  def saved_history?(record, transitions) do
    Enum.all?(Map.get(record, :native_branch_history, %{}), fn
      {id, %{__struct__: NativePreparedBranchRetirement} = saved} ->
        receipts = [
          record.created_machine.backend_identity.receipt | Enum.map(transitions, & &1.receipt)
        ]

        saved.request["creation"]["source"] in receipts and
          not Map.has_key?(record.disk_expansions, id) and not Map.has_key?(record.captures, id) and
          Enum.all?(transitions, &(&1.receipt["material"]["operation_id"] != id))

      _ ->
        true
    end)
  end
end
