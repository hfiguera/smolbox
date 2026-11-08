defmodule SmolBox.Embedded.NativePreparedBranchRetirement do
  @moduledoc false
  alias SmolBox.Embedded.{PreparedBranchRetirement, Shape}
  alias SmolBox.{ManagedMachine, Profile, Validation}

  @enforce_keys [:version, :request, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          request: map(),
          proof: PreparedBranchRetirement.t()
        }

  def eligible?(
        %ManagedMachine{
          branch: %{
            state: :unknown,
            native_authority: %{
              collected_publication: nil,
              completion: nil,
              prepared_retirement: nil,
              partial_collection: nil
            }
          },
          operation: :branch_child
        } = child
      ),
      do: ManagedMachine.validate(child) == :ok

  def eligible?(_), do: false

  def pending?(parent, child),
    do:
      ManagedMachine.validate(parent) == :ok and eligible?(child) and
        parent.active_branch == child.id and parent.operation == :branch and
        parent.branch_children[child.id] == false and
        not Map.has_key?(parent.native_branch_history, child.id) and
        parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        child.branch.source == ManagedMachine.key(parent)

  def request(authority) do
    request = %{"creation" => authority.request, "quiesced" => true}
    Map.put(request, "request_sha256", PreparedBranchRetirement.request_digest(request))
  end

  def valid?(%__MODULE__{proof: %PreparedBranchRetirement{}} = saved),
    do:
      Validation.struct_shape?(saved, __MODULE__) and
        Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
        PreparedBranchRetirement.matches?(saved.proof, saved.request)

  def valid?(_), do: false

  def valid?(saved, authority),
    do:
      valid?(saved) and saved.request == request(authority) and
        Enum.all?(
          ~w(collected_publication completion release retirement backing deletion delete_continuation delete_cleanup delete_collection)a,
          &(Map.fetch!(authority, &1) == nil)
        )

  def record?(%{branch: %{native_authority: %{prepared_retirement: nil}}}), do: true

  def record?(
        %{branch: %{native_authority: %{prepared_retirement: %__MODULE__{} = saved}}} = child
      ),
      do:
        valid?(saved, child.branch.native_authority) and saved.version < child.version and
          closed?(child) and
          plan?(saved, child.spec.profile) and
          saved.proof.retirement["intent"]["source_pid"] ==
            child.branch.source_machine.backend_identity.pid_identity

  def record?(_), do: false

  defp closed?(child),
    do:
      child.state == :deleted and child.branch.state == :closed and
        ManagedMachine.idle?(child) and child.reservation == nil and child.reserved_ports == [] and
        child.absence_at_ms != nil and child.created_machine == nil and
        child.observed_machine == nil

  def plan?(saved, profile),
    do:
      saved.proof.retirement["intent"]["plan"]["ordinary_child"] ==
        Map.new(Profile.resources(profile), fn {key, value} -> {Atom.to_string(key), value} end)

  def preserved?(nil, nil, _), do: true
  def preserved?(nil, %__MODULE__{version: version}, version), do: true
  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false

  def source?(record, id, %__MODULE__{} = saved) do
    receipt = saved.request["creation"]["source"]
    intent = saved.proof.retirement["intent"]
    root = record.created_machine.backend_identity.receipt
    profile = record.spec.profile

    valid?(saved) and Validation.identifier?(id) and record.branch_children[id] == true and
      id != record.active_branch and saved.request["creation"]["child"]["operation_id"] == id and
      Map.delete(receipt, "material") == Map.delete(root, "material") and
      Shape.receipt?(root, 2) and
      intent["approval"]["host_overhead_mb"] == profile.host_overhead_mb and plan?(saved, profile)
  end

  def source?(_, _, _), do: false

  def history?(record, transitions) do
    Enum.all?(Map.get(record, :native_branch_history, %{}), fn
      {id, %__MODULE__{} = saved} ->
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
