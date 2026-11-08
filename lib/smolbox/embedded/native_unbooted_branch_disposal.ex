defmodule SmolBox.Embedded.NativeUnbootedBranchDisposal do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
    NativeBranchBacking,
    NativeBranchRetirement,
    NativeCollectedBranchPublication,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal
  }

  alias SmolBox.{ManagedMachine, Profile, Validation}
  @enforce_keys [:version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil, completion_version: nil]

  @type t :: %__MODULE__{
          version: pos_integer(),
          request: map(),
          proof: UnbootedBranchDisposal.t() | nil,
          completion_version: pos_integer() | nil
        }

  def request(authority, version) do
    id =
      BranchCanonical.digest([
        "smolbox-native-unbooted-disposal-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(authority.request, :creation_request)
      ])

    intent = %{"operation_id" => "dispose-" <> binary_part(id, 0, 32), "quiesced" => true}

    intent =
      Map.put(
        intent,
        "request_sha256",
        UnbootedBranchDisposal.request_digest(intent, authority.request)
      )

    %{"creation" => authority.request, "request" => intent}
  end

  def new(authority, version),
    do: %__MODULE__{version: version, request: request(authority, version)}

  def valid?(%__MODULE__{} = saved, authority),
    do:
      Validation.struct_shape?(saved, __MODULE__) and
        Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
        UnbootedBranchDisposal.request?(saved.request) and
        saved.request == request(authority, saved.version) and
        Enum.all?(
          ~w(completion prepared_retirement release deletion delete_continuation delete_cleanup delete_collection)a,
          &(Map.fetch!(authority, &1) == nil)
        ) and completion?(saved) and retirement?(authority) and backing?(authority)

  def valid?(_, _), do: false
  defp retirement?(%{retirement: nil}), do: true

  defp retirement?(%{retirement: %{proof: %UnbootedBranchChildAbsence{}} = saved} = authority),
    do:
      is_struct(saved, NativeBranchRetirement) and NativeBranchRetirement.valid?(saved, authority)

  defp retirement?(_), do: false

  defp backing?(%{backing: nil}), do: true

  defp backing?(%{backing: saved} = authority),
    do: is_struct(saved, NativeBranchBacking) and NativeBranchBacking.valid?(saved, authority)

  defp completion?(%{proof: nil, completion_version: nil}), do: true

  defp completion?(%{proof: %UnbootedBranchDisposal{} = proof} = saved),
    do:
      Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991) and
        UnbootedBranchDisposal.matches?(proof, saved.request)

  defp completion?(_), do: false

  def eligible?(
        %ManagedMachine{
          branch: %{
            native_authority: %{
              completion: nil,
              prepared_retirement: nil,
              partial_collection: nil
            }
          }
        } =
          child
      ),
      do:
        child.state == :unknown and child.branch.state in [:unknown, :disposal_pending] and
          child.operation == :branch_child and
          child.reservation == Profile.resources(child.spec.profile) and
          child.reserved_ports == [] and
          child.created_machine == nil and child.observed_machine == nil and
          child.absence_at_ms == nil

  def eligible?(_), do: false

  def pending?(parent, child) do
    with :ok <- ManagedMachine.validate(parent),
         :ok <- ManagedMachine.validate(child),
         true <- eligible?(child) do
      parent.active_branch == child.id and parent.operation == :branch and
        parent.branch_children[child.id] == false and
        parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        child.branch.source == ManagedMachine.key(parent) and
        NativeCollectedBranchPublication.source_pending?(parent, child)
    else
      _ -> false
    end
  end

  def record?(%{branch: %{native_authority: %{disposal: nil}}}), do: true

  def record?(
        %{branch: %{native_authority: %{disposal: %__MODULE__{} = saved} = authority}} = child
      ),
      do: valid?(saved, authority) and saved.version < child.version and state?(child, saved)

  def record?(_), do: false

  defp state?(child, %{proof: nil}),
    do: child.branch.state == :disposal_pending and eligible?(child)

  defp state?(child, saved),
    do:
      tombstone?(child) and saved.completion_version < child.version and
        plan?(saved.proof, child.spec.profile) and
        get_in(saved.proof.publication, ~w(change child_origin intent source_pid)) ==
          child.branch.source_machine.backend_identity.pid_identity

  defp tombstone?(child),
    do:
      child.state == :deleted and disposed_state?(child) and ManagedMachine.idle?(child) and
        child.reservation == nil and child.reserved_ports == [] and child.absence_at_ms != nil and
        child.created_machine == nil and child.observed_machine == nil

  defp disposed_state?(%{branch: %{state: :disposed, native_authority: %{retirement: nil}}}),
    do: true

  defp disposed_state?(%{
         branch: %{
           state: :retired,
           native_authority: %{retirement: %{proof: %UnbootedBranchChildAbsence{}}}
         }
       }),
       do: true

  defp disposed_state?(%{
         branch: %{
           state: :closed,
           native_authority: %{
             retirement: %{proof: %UnbootedBranchChildAbsence{}},
             backing: %{proof: %BranchBackingRelease{}}
           }
         }
       }),
       do: true

  defp disposed_state?(%{
         branch: %{
           state: :backing_pending,
           native_authority: %{
             retirement: %{proof: %UnbootedBranchChildAbsence{}},
             backing: %{proof: nil}
           }
         }
       }),
       do: true

  defp disposed_state?(_), do: false

  def plan?(proof, profile),
    do:
      get_in(proof.publication, ~w(change child_origin intent plan ordinary_child)) ==
        Map.new(Profile.resources(profile), fn {key, value} -> {Atom.to_string(key), value} end)

  def preserved?(nil, nil, _), do: true

  def preserved?(
        nil,
        %__MODULE__{version: version, proof: nil, completion_version: nil},
        version
      ),
      do: true

  def preserved?(
        %__MODULE__{proof: nil, completion_version: nil} = before,
        %__MODULE__{} = after_saved,
        version
      ),
      do:
        %{after_saved | proof: nil, completion_version: nil} == before and
          (after_saved.proof == nil or after_saved.completion_version == version)

  def preserved?(%__MODULE__{} = before, before, _), do: true
  def preserved?(_, _, _), do: false
end
