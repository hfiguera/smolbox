defmodule SmolBox.Store.NativePreparedBranchRetirementContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Embedded.{
    BranchCanonical,
    NativeGrowth,
    NativePreparedBranchRetirement,
    NativePreparedBranchRetirementResult,
    PreparedBranchRetirement
  }

  alias SmolBox.{ManagedMachine, Profile}
  alias SmolBox.Store.{Codec, Contract, NativeBranchContract}

  # Hash/correlation models only; no VM, SDK enrollment or process termination.
  def prepare(adapter, store, hold) do
    {parent, child, completion} = NativeBranchContract.prepare(adapter, store, hold)

    assert {:ok, _} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               child,
               :accepted,
               :dispatching,
               1101
             )

    parent = fetch(adapter, store, parent)

    assert {:ok, child} =
             NativeBranchContract.advance(
               adapter,
               store,
               parent,
               child,
               :dispatching,
               :unknown,
               1102
             )

    parent = fetch(adapter, store, parent)
    request = NativePreparedBranchRetirement.request(child.branch.native_authority)
    intent = completion.completion.publication["change"]["child_origin"]["intent"]
    proof = proof(intent, request)

    result = %NativePreparedBranchRetirementResult{
      version: child.version,
      source: parent.observed_machine,
      proof: proof
    }

    assert NativePreparedBranchRetirementResult.bound?(result, parent, child)
    assert {:ok, usage} = adapter.usage(store, parent.worker_id)
    {parent, child, result, usage}
  end

  def rehash_intent(intent) do
    Map.put(
      intent,
      "request_sha256",
      BranchCanonical.digest([
        "smolbox-initial-branch-admission-v1",
        "9f446ae00219148ca4a703914f44a8e2fab11655",
        "shared-materialized-ram",
        BranchCanonical.ordered(intent["source"], :receipt),
        BranchCanonical.ordered(intent["child"], :child),
        BranchCanonical.ordered(intent["approval"], :approval),
        BranchCanonical.ordered(intent["plan"], :plan),
        intent["source_pid"],
        intent["epoch"]
      ])
    )
  end

  def proof(intent, request) do
    retirement = %{
      "schema" => 1,
      "intent" => intent,
      "proof_sha256" =>
        BranchCanonical.digest([
          "smolbox-initial-branch-retirement-v1",
          BranchCanonical.ordered(intent, :intent)
        ])
    }

    proof = %{
      "schema" => 1,
      "request_sha256" => request["request_sha256"],
      "retirement" => retirement
    }

    proof = Map.put(proof, "proof_sha256", PreparedBranchRetirement.proof_digest(proof))
    assert {:ok, proof} = PreparedBranchRetirement.from_wire(proof)
    proof
  end

  def fetch(adapter, store, record) do
    assert {:ok, saved} = adapter.machine(store, :fetch, [ManagedMachine.key(record)])
    saved
  end

  def resolve(adapter, store, parent, child, result, now),
    do:
      adapter.machine(store, :branch_resolve, [
        ManagedMachine.key(parent),
        Contract.guard(parent),
        child.id,
        result.source,
        result,
        now
      ])

  def complete(adapter, store, hold) do
    {parent, child, result, usage} = prepare(adapter, store, hold)
    reject_invalid(adapter, store, parent, child, result, usage)

    assert {:ok, retired} = resolve(adapter, store, parent, child, result, 1103)
    source = fetch(adapter, store, parent)
    saved = retired.branch.native_authority.prepared_retirement
    assert saved.version == child.version and saved.proof == result.proof
    assert saved.request == NativePreparedBranchRetirement.request(child.branch.native_authority)

    assert retired.branch.state == :closed and retired.state == :deleted and
             retired.branch.retired_at_ms == 1103

    assert retired.reservation == nil and retired.created_machine == nil and
             retired.observed_machine == nil

    assert source.native_branch_history == %{child.id => saved}
    assert source.branch_children == %{child.id => true} and source.active_branch == nil

    assert source.created_machine == parent.created_machine and
             source.observed_machine == result.source

    assert NativeGrowth.head(source) == NativeGrowth.head(parent)
    assert {:ok, []} = NativeGrowth.transitions(source)
    assert {:ok, expected} = adapter.usage(store, parent.worker_id)

    assert expected ==
             Map.merge(
               usage,
               Map.merge(
                 Profile.resources(child.spec.profile),
                 child.branch.spec.policy.resources,
                 fn _, a, b -> a + b end
               ),
               fn _, a, b -> a - b end
             )

    for record <- [source, retired], do: roundtrip(record)

    assert {:error, _} =
             resolve(adapter, store, source, retired, %{result | version: retired.version}, 1104)

    assert {:ok, ^expected} = adapter.usage(store, parent.worker_id)
    {source, retired, result, expected}
  end

  defp reject_invalid(adapter, store, parent, child, result, usage) do
    args = [ManagedMachine.key(parent), Contract.guard(parent), child.id]

    for invalid <- [
          :absent,
          result.proof,
          PreparedBranchRetirement.to_wire(result.proof),
          %{result | version: child.version + 1},
          %{result | source: %{result.source | state: :unknown}},
          put_in(result.proof.request_sha256, String.duplicate("0", 64))
        ] do
      assert {:error, _} =
               adapter.machine(store, :branch_resolve, args ++ [result.source, invalid, 1103])

      assert fetch(adapter, store, parent) == parent
      assert fetch(adapter, store, child) == child
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end
  end

  def roundtrip(record) do
    assert {:ok, <<"smolbox-record-v36\0", body::binary>> = bytes} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(bytes)

    for version <- 1..35,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "tail")

    assert {:error, _} =
             Codec.decode("smolbox-record-v36\0" <> :erlang.term_to_binary(record, compressed: 9))

    bytes
  end
end
