defmodule SmolBox.Embedded.NativePreparedBranchRetirement do
  @moduledoc false
  alias SmolBox.Embedded.PreparedBranchRetirement
  alias SmolBox.ManagedMachineState

  @enforce_keys [:version, :request, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          request: map(),
          proof: PreparedBranchRetirement.t()
        }

  def request(authority) do
    request = %{"creation" => authority.request, "quiesced" => true}
    Map.put(request, "request_sha256", PreparedBranchRetirement.request_digest(request))
  end

  defdelegate valid?(saved), to: PreparedBranchRetirement, as: :saved_valid?

  def valid?(saved, authority),
    do:
      valid?(saved) and saved.request == request(authority) and
        Enum.all?(
          ~w(completion release retirement backing deletion delete_continuation delete_cleanup delete_collection)a,
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
        ManagedMachineState.idle?(child) and child.reservation == nil and
        child.reserved_ports == [] and
        child.absence_at_ms != nil and child.created_machine == nil and
        child.observed_machine == nil

  defdelegate plan?(saved, profile), to: PreparedBranchRetirement, as: :saved_plan?

  def preserved?(nil, nil, _), do: true
  def preserved?(nil, %__MODULE__{version: version}, version), do: true
  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
