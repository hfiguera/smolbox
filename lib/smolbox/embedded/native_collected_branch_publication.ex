defmodule SmolBox.Embedded.NativeCollectedBranchPublication do
  @moduledoc false
  alias SmolBox.Embedded.{BranchCanonical, BranchPublication, NativeGrowth}
  alias SmolBox.{ManagedMachine, Profile, Validation}

  @enforce_keys [:version, :request, :platform]
  @derive {Inspect, only: [:version, :platform]}
  defstruct @enforce_keys ++ [proof: nil, completion_version: nil]

  @type t :: %__MODULE__{
          version: pos_integer(),
          request: map(),
          platform: String.t(),
          proof: %BranchPublication{} | nil,
          completion_version: pos_integer() | nil
        }

  def new(authority, version, platform),
    do: %__MODULE__{
      version: version,
      request: %{"creation" => authority.request, "quiesced" => true},
      platform: platform
    }

  def valid?(%__MODULE__{} = saved, authority),
    do:
      Validation.struct_shape?(saved, __MODULE__) and
        Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
        saved.platform in ~w(linux macos) and
        %{saved | proof: nil, completion_version: nil} ==
          new(authority, saved.version, saved.platform) and
        authority.prepared_retirement == nil and
        collection_platform?(authority.partial_collection, saved.platform) and
        completion?(saved, authority)

  def valid?(_, _), do: false

  defp collection_platform?(nil, _), do: true
  defp collection_platform?(%{platform: platform}, platform), do: true
  defp collection_platform?(_, _), do: false

  defp completion?(%{proof: nil, completion_version: nil}, authority),
    do:
      Enum.all?(
        ~w(completion disposal partial_disposal release retirement backing deletion delete_continuation delete_cleanup delete_collection)a,
        &(Map.fetch!(authority, &1) == nil)
      )

  defp completion?(%{proof: %BranchPublication{} = proof} = saved, authority),
    do:
      BranchPublication.matches?(proof, authority.request) and
        proof.change["platform"] == saved.platform and
        Validation.integer?(saved.completion_version, saved.version + 1, 9_007_199_254_740_991) and
        Enum.all?([authority.completion, authority.disposal, authority.partial_disposal], fn
          nil -> true
          %{publication: publication} -> publication == BranchPublication.to_wire(proof)
          %{proof: nil} -> true
          %{proof: %{publication: publication}} -> publication == BranchPublication.to_wire(proof)
          _ -> false
        end) and collection?(authority.partial_collection, saved)

  defp completion?(_, _), do: false
  defp collection?(nil, _), do: true
  defp collection?(%{platform: platform, proof: nil}, %{platform: platform}), do: true

  defp collection?(%{platform: platform, proof: proof}, %{platform: platform} = saved),
    do:
      proof.publication_sha256 ==
        BranchCanonical.digest(
          BranchCanonical.ordered(BranchPublication.to_wire(saved.proof), :publication)
        )

  defp collection?(_, _), do: false

  def eligible?(%ManagedMachine{branch: %{state: :unknown, native_authority: authority}} = child),
    do:
      child.state == :unknown and child.operation == :branch_child and
        child.reservation == Profile.resources(child.spec.profile) and child.reserved_ports == [] and
        child.created_machine == nil and child.observed_machine == nil and
        child.absence_at_ms == nil and
        Enum.all?(
          ~w(completion prepared_retirement disposal partial_disposal release retirement backing deletion)a,
          &(Map.fetch!(authority, &1) == nil)
        )

  def eligible?(_), do: false

  def pending?(parent, child),
    do:
      ManagedMachine.validate(parent) == :ok and ManagedMachine.validate(child) == :ok and
        eligible?(child) and related?(parent, child) and source_pending?(parent, child)

  defp related?(parent, child),
    do:
      parent.active_branch == child.id and parent.operation == :branch and
        parent.branch_children[child.id] == false and parent.worker_id == child.worker_id and
        parent.worker_generation == child.worker_generation and
        child.branch.source == ManagedMachine.key(parent)

  # An accepted, still unacknowledged control cannot authorize a different
  # completion. A recorded publication must match both the paired head/history
  # and every later ready/disposal result; it is never appended a second time.
  def source_pending?(parent, child) do
    case child.branch.native_authority.collected_publication do
      %{proof: %BranchPublication{} = proof} -> source_matches?(parent, child, proof)
      _ -> original_source?(parent, child)
    end
  end

  def publication_pending?(parent, child, %BranchPublication{} = proof) do
    case child.branch.native_authority.collected_publication do
      nil ->
        original_source?(parent, child) and
          proof.previous == child.branch.native_authority.request["source"]

      %{proof: ^proof} ->
        source_matches?(parent, child, proof)

      _ ->
        false
    end
  end

  def publication_pending?(parent, child, wire) do
    case BranchPublication.from_wire(wire) do
      {:ok, proof} -> publication_pending?(parent, child, proof)
      _ -> false
    end
  end

  defp original_source?(parent, child),
    do:
      not Map.has_key?(parent.native_branch_history, child.id) and
        head?(parent, child.branch.native_authority.request["source"])

  defp source_matches?(parent, child, proof),
    do: parent.native_branch_history[child.id] == proof and head?(parent, proof.receipt)

  defp head?(parent, receipt),
    do: match?({:ok, ^receipt, _, _}, NativeGrowth.head(parent))

  def record?(%{branch: %{native_authority: %{collected_publication: nil}}}), do: true

  def record?(
        %{
          branch: %{native_authority: %{collected_publication: %__MODULE__{} = saved} = authority}
        } = child
      ),
      do:
        valid?(saved, authority) and saved.version < child.version and
          if(saved.proof == nil,
            do: eligible?(child),
            else:
              saved.completion_version < child.version and
                get_in(saved.proof.change, ~w(child_origin intent source_pid)) ==
                  child.branch.source_machine.backend_identity.pid_identity and
                get_in(saved.proof.change, ~w(child_origin intent plan ordinary_child)) ==
                  Map.new(Profile.resources(child.spec.profile), fn {key, value} ->
                    {Atom.to_string(key), value}
                  end)
          )

  def record?(_), do: false
  def preserved?(nil, nil, _), do: true

  def preserved?(
        nil,
        %__MODULE__{version: version, proof: nil, completion_version: nil},
        version
      ),
      do: true

  def preserved?(%__MODULE__{proof: nil} = before, %__MODULE__{} = after_action, _),
    do: %{after_action | proof: nil, completion_version: nil} == before

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
