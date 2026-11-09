defmodule SmolBox.Embedded.NativeBranchRetirement do
  @moduledoc false
  alias SmolBox.ManagedMachineState

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchChildAbsence,
    BranchCompletion,
    BranchPublication,
    NativeGrowth,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal
  }

  alias SmolBox.{ManagedMachine, Validation}
  @enforce_keys [:version, :proof]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys

  # Observation has no SDK mutation intent. Its exact request still fences the
  # child version between public read, native proof and the paired store commit.
  def request(%{branch: %{native_authority: %{retirement: %__MODULE__{} = saved}}}),
    do: {:ok, saved.proof.request}

  def request(
        %{
          branch: %{
            native_authority: %{disposal: %{proof: %UnbootedBranchDisposal{}}} = authority
          }
        } = child
      ) do
    if eligible?(child), do: {:ok, unbooted_intent(authority, child.version)}, else: :error
  end

  def request(%{branch: %{native_authority: authority}} = child) do
    with true <- eligible?(child),
         {:ok, receipt, _, _} <- NativeGrowth.head(child) do
      {:ok, intent(authority, child.version, receipt)}
    else
      _ -> :error
    end
  end

  def request(_), do: :error

  def eligible?(
        %{
          __struct__: ManagedMachine,
          branch: %{native_authority: %{completion: %BranchCompletion{}}}
        } = child
      ),
      do:
        child.state == :deleted and ManagedMachineState.idle?(child) and child.reservation == nil and
          child.branch.state in [:ready, :held, :released, :retired, :closed]

  def eligible?(
        %{
          __struct__: ManagedMachine,
          branch: %{
            native_authority: %{completion: nil, disposal: %{proof: %UnbootedBranchDisposal{}}}
          }
        } = child
      ),
      do:
        child.state == :deleted and ManagedMachineState.idle?(child) and child.reservation == nil and
          child.branch.state in [:disposed, :retired, :backing_pending, :closed] and
          child.created_machine == nil and child.observed_machine == nil

  def eligible?(_), do: false

  def intent(authority, version, receipt) do
    digest =
      BranchCanonical.digest([
        "smolbox-native-branch-retirement-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(receipt, :receipt),
        BranchCanonical.ordered(BranchCompletion.to_wire(authority.completion), :completion)
      ])

    %{
      "completion" => BranchCompletion.to_wire(authority.completion),
      "child" => receipt,
      "operation_id" => "retire-" <> binary_part(digest, 0, 32),
      "request_sha256" => digest,
      "quiesced" => true
    }
  end

  def unbooted_intent(authority, version) do
    disposal = UnbootedBranchDisposal.to_wire(authority.disposal.proof)

    digest =
      BranchCanonical.digest([
        "smolbox-native-unbooted-retirement-v1",
        authority.fingerprint,
        version,
        BranchCanonical.ordered(disposal, :unbooted_disposal)
      ])

    request = %{
      "disposal" => disposal,
      "operation_id" => "retire-" <> binary_part(digest, 0, 32),
      "quiesced" => true
    }

    Map.put(request, "request_sha256", UnbootedBranchChildAbsence.request_digest(request))
  end

  def publication(%{completion: %BranchCompletion{publication: publication}}),
    do: BranchPublication.from_wire(publication)

  def publication(%{
        completion: nil,
        disposal: %{proof: %UnbootedBranchDisposal{publication: publication}}
      }),
      do: BranchPublication.from_wire(publication)

  def publication(_), do: :error

  def matches?(%BranchChildAbsence{} = proof, request),
    do: BranchChildAbsence.matches?(proof, request)

  def matches?(%UnbootedBranchChildAbsence{} = proof, request),
    do: UnbootedBranchChildAbsence.matches?(proof, request)

  def matches?(_, _), do: false

  def valid?(
        %__MODULE__{proof: %UnbootedBranchChildAbsence{} = proof} = saved,
        %{completion: nil, disposal: %{proof: %UnbootedBranchDisposal{}}} = authority
      ),
      do:
        Validation.struct_shape?(saved, __MODULE__) and
          Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
          UnbootedBranchChildAbsence.valid?(proof) and
          proof.request == unbooted_intent(authority, saved.version)

  def valid?(
        %__MODULE__{proof: %BranchChildAbsence{} = proof} = saved,
        %{completion: %BranchCompletion{}} = authority
      ),
      do:
        Validation.struct_shape?(saved, __MODULE__) and
          Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
          BranchChildAbsence.valid?(proof) and
          proof.request == intent(authority, saved.version, proof.request["child"])

  def valid?(_, _), do: false

  # Preserve earlier experimental envelopes without treating their old state as
  # new native proof. Ratification still requires fresh fenced absence evidence.
  def record?(%{
        branch: %{native_authority: %{retirement: nil}},
        backend_assignment: %{version: 2}
      }),
      do: true

  def record?(
        %{branch: %{native_authority: %{retirement: %__MODULE__{} = saved} = authority}} = child
      ) do
    with true <-
           eligible?(child) and child.branch.state in [:retired, :backing_pending, :closed] and
             valid?(saved, authority),
         true <- child_bound?(saved, child),
         do: saved.version < child.version,
         else: (_ -> false)
  end

  def record?(_), do: false

  defp child_bound?(%{proof: %UnbootedBranchChildAbsence{} = proof}, child),
    do:
      proof.request["disposal"] ==
        UnbootedBranchDisposal.to_wire(child.branch.native_authority.disposal.proof)

  defp child_bound?(saved, child) do
    case NativeGrowth.head(child) do
      {:ok, receipt, _, _} -> saved.proof.request["child"] == receipt
      _ -> false
    end
  end

  def preserved?(nil, nil, _version), do: true
  def preserved?(nil, %__MODULE__{version: version}, version), do: true
  def preserved?(%__MODULE__{} = saved, saved, _version), do: true
  def preserved?(_, _, _), do: false
end
