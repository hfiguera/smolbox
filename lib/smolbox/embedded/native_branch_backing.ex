defmodule SmolBox.Embedded.NativeBranchBacking do
  @moduledoc false
  alias SmolBox.Embedded.{
    BranchBackingRelease,
    BranchCanonical,
    BranchCompletion,
    NativeBranchRetirement,
    NativeGrowth,
    PartialBranchBackingRelease,
    PartialBranchChildAbsence,
    PartialBranchDisposal,
    UnbootedBranchBackingRelease,
    UnbootedBranchChildAbsence,
    UnbootedBranchDisposal
  }

  alias SmolBox.{ManagedMachine, Validation}
  @enforce_keys [:version, :request]
  @derive {Inspect, only: [:version]}
  defstruct @enforce_keys ++ [proof: nil]

  def unbooted?(%{
        branch: %{
          native_authority: %{completion: nil, disposal: %{proof: %UnbootedBranchDisposal{}}}
        }
      }),
      do: true

  def unbooted?(_), do: false

  def partial?(%{
        branch: %{
          native_authority: %{
            completion: nil,
            partial_disposal: %{proof: %PartialBranchDisposal{}}
          }
        }
      }),
      do: true

  def partial?(_), do: false
  def source_scoped?(child), do: unbooted?(child) or partial?(child)

  def pending_state(child), do: if(source_scoped?(child), do: :backing_pending, else: :retired)

  def child_receipt(%{
        branch: %{
          native_authority: %{
            completion: nil,
            disposal: %{proof: %UnbootedBranchDisposal{} = disposal}
          }
        }
      }),
      do: {:ok, get_in(disposal.publication, ~w(change child))}

  def child_receipt(%{
        branch: %{
          native_authority: %{
            completion: nil,
            partial_disposal: %{proof: %PartialBranchDisposal{} = disposal}
          }
        }
      }),
      do:
        {:ok,
         get_in(disposal.release, ["receipt"]) || get_in(disposal.publication, ~w(change child))}

  def child_receipt(child) do
    case NativeGrowth.head(child) do
      {:ok, receipt, _, _} -> {:ok, receipt}
      _ -> :error
    end
  end

  def intent(
        %{completion: nil, disposal: %{proof: %UnbootedBranchDisposal{} = disposal}} = authority,
        version,
        source,
        child
      ) do
    id =
      BranchCanonical.digest([
        "smolbox-native-unbooted-backing-v1",
        authority.fingerprint,
        version,
        authority.retirement.proof.proof_sha256,
        BranchCanonical.ordered(source, :receipt),
        BranchCanonical.ordered(child, :receipt)
      ])

    request = %{
      "disposal" => UnbootedBranchDisposal.to_wire(disposal),
      "source" => source,
      "child" => child,
      "operation_id" => "backing-" <> binary_part(id, 0, 32),
      "quiesced" => true,
      "backing_removed" => true
    }

    Map.put(request, "request_sha256", UnbootedBranchBackingRelease.request_digest(request))
  end

  def intent(
        %{completion: nil, partial_disposal: %{proof: %PartialBranchDisposal{} = disposal}} =
          authority,
        version,
        source,
        child
      ) do
    id =
      BranchCanonical.digest([
        "smolbox-native-partial-backing-v1",
        authority.fingerprint,
        version,
        authority.retirement.proof.proof_sha256,
        BranchCanonical.ordered(source, :receipt),
        BranchCanonical.ordered(child, :receipt)
      ])

    request = %{
      "disposal" => PartialBranchDisposal.to_wire(disposal),
      "source" => source,
      "child" => child,
      "operation_id" => "backing-" <> binary_part(id, 0, 32),
      "quiesced" => true,
      "backing_removed" => true
    }

    Map.put(request, "request_sha256", PartialBranchBackingRelease.request_digest(request))
  end

  def intent(authority, version, source, child) do
    id =
      BranchCanonical.digest([
        "smolbox-native-branch-backing-v1",
        authority.fingerprint,
        version,
        authority.retirement.proof.proof_sha256,
        BranchCanonical.ordered(source, :receipt),
        BranchCanonical.ordered(child, :receipt)
      ])

    request = %{
      "completion" => BranchCompletion.to_wire(authority.completion),
      "source" => source,
      "child" => child,
      "operation_id" => "backing-" <> binary_part(id, 0, 32),
      "quiesced" => true,
      "backing_removed" => true
    }

    Map.put(request, "request_sha256", BranchBackingRelease.request_digest(request))
  end

  def valid?(
        %__MODULE__{} = saved,
        %{retirement: %NativeBranchRetirement{} = retirement} = authority
      ),
      do:
        origin?(authority) and Validation.struct_shape?(saved, __MODULE__) and
          Validation.integer?(saved.version, 1, 9_007_199_254_740_991) and
          retirement.version < saved.version and
          NativeBranchRetirement.valid?(retirement, authority) and request?(saved.request) and
          saved.request ==
            intent(authority, saved.version, saved.request["source"], saved.request["child"]) and
          acknowledgement?(saved.proof, saved.request)

  def valid?(_, _), do: false

  defp acknowledgement?(nil, _), do: true

  defp acknowledgement?(%BranchBackingRelease{} = proof, request),
    do: matches?(proof, request)

  defp acknowledgement?(_, _), do: false

  defp origin?(%{completion: %BranchCompletion{}, disposal: nil}), do: true

  defp origin?(%{
         completion: nil,
         disposal: %{proof: %UnbootedBranchDisposal{}},
         retirement: %{proof: %UnbootedBranchChildAbsence{}}
       }),
       do: true

  defp origin?(%{
         completion: nil,
         partial_disposal: %{proof: %PartialBranchDisposal{}},
         retirement: %{proof: %PartialBranchChildAbsence{}}
       }),
       do: true

  defp origin?(_), do: false

  def request?(%{"disposal" => %{"request" => %{"collection_request" => _}}} = request),
    do: PartialBranchBackingRelease.request?(request)

  def request?(%{"disposal" => _} = request), do: UnbootedBranchBackingRelease.request?(request)
  def request?(request), do: BranchBackingRelease.request?(request)

  def matches?(proof, %{"disposal" => %{"request" => %{"collection_request" => _}}} = request),
    do: PartialBranchBackingRelease.matches?(proof, request)

  def matches?(proof, %{"disposal" => _} = request),
    do: UnbootedBranchBackingRelease.matches?(proof, request)

  def matches?(proof, request), do: BranchBackingRelease.matches?(proof, request)

  def platform(%{"disposal" => %{"request" => %{"collection_request" => _}}} = request),
    do: PartialBranchBackingRelease.platform(request)

  def platform(%{"disposal" => _} = request), do: UnbootedBranchBackingRelease.platform(request)
  def platform(request), do: BranchBackingRelease.platform(request)

  def record?(%{branch: %{native_authority: %{backing: nil}}}), do: true

  def record?(
        %{branch: %{native_authority: %{backing: %__MODULE__{} = saved} = authority}} = child
      ) do
    with true <- NativeBranchRetirement.eligible?(child) and valid?(saved, authority),
         true <- saved.version < child.version,
         {:ok, receipt} <- child_receipt(child),
         do:
           receipt == saved.request["child"] and
             child.branch.state == if(saved.proof == nil, do: pending_state(child), else: :closed),
         else: (_ -> false)
  end

  def record?(_), do: false

  def pair?(parent, child) do
    with true <- origin?(child.branch.native_authority),
         true <- NativeBranchRetirement.pair?(parent, child),
         true <- child.branch.state in [:retired, :backing_pending, :closed],
         %NativeBranchRetirement{} <- child.branch.native_authority.retirement do
      parent.state == :deleted and ManagedMachine.idle?(parent) and parent.reservation == nil and
        parent.active_branch == nil and parent.branch_children[child.id] == true and
        Enum.all?(parent.branch_children, fn {_, retired} -> retired == true end)
    else
      _ -> false
    end
  end

  def preserved?(nil, nil, _), do: true
  def preserved?(nil, %__MODULE__{version: version, proof: nil}, version), do: true

  def preserved?(%__MODULE__{proof: nil} = saved, %__MODULE__{} = next, _),
    do: %{next | proof: nil} == saved

  def preserved?(%__MODULE__{} = saved, saved, _), do: true
  def preserved?(_, _, _), do: false
end
