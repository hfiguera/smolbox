defmodule SmolBox.NativePartialBranchCleanupTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    NativePartialBranchCleanup,
    NativePartialBranchCleanupResult,
    NativePartialBranchDisposalResult,
    PartialBranchDisposalCleanup
  }

  alias SmolBox.{Branch, ManagedMachine}

  alias SmolBox.Store.{
    Codec,
    Contract,
    Memory,
    NativePartialBranchBackingContract,
    NativePartialBranchCleanupContract,
    NativePartialBranchDisposalContract,
    NativePartialBranchRetirementContract
  }

  alias NativePartialBranchCleanupContract, as: Cleanup
  alias SmolBox.Runtime.NativePartialBranchDisposal, as: PublicDisposal

  for mode <- [:held, :pre_release, :initial_release, :explicit_release] do
    test "#{mode} paired cleanup freezes separate authority and releases only ordinary capacity" do
      Cleanup.complete(Memory, start_supervised!(Memory), unquote(mode))
    end
  end

  test "claims and repeated acceptance retain the exact action while stale results cannot commit" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Cleanup.prepare(Memory, store, :held)
    assert {:ok, pending} = Cleanup.accept(Memory, store, parent, child, child.version, 1401)
    source = Cleanup.fetch(Memory, store, parent)
    result = Cleanup.result(pending, metadata)

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1402, 10_000])

    saved = current.branch.native_authority.partial_disposal.cleanup
    assert saved == pending.branch.native_authority.partial_disposal.cleanup
    assert {:ok, ^current} = Cleanup.accept(Memory, store, source, current, saved.version, 1403)
    assert {:error, _} = Cleanup.resolve(Memory, store, source, current, result, 1404)
    assert Cleanup.fetch(Memory, store, child) == current
    assert {:ok, ^usage} = Memory.usage(store, source.worker_id)

    assert {:ok, _} =
             Cleanup.resolve(
               Memory,
               store,
               source,
               current,
               %{result | version: current.version},
               1404
             )
  end

  test "a cleanup action cannot be accepted before disposal or under another platform or version" do
    store = start_supervised!(Memory)

    {parent, collected, _, usage} =
      NativePartialBranchDisposalContract.prepare(Memory, store, :held)

    assert {:error, _} = Cleanup.accept(Memory, store, parent, collected, collected.version, 1400)

    assert {:ok, child} =
             NativePartialBranchDisposalContract.accept(
               Memory,
               store,
               parent,
               collected,
               collected.version,
               1400
             )

    parent = Cleanup.fetch(Memory, store, parent)

    for {version, platform} <- [{child.version - 1, "macos"}, {child.version, "linux"}] do
      assert {:error, _} = Cleanup.accept(Memory, store, parent, child, version, 1401, platform)
    end

    assert Cleanup.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "ordinary disposal cannot bypass an accepted cleanup or perform helper IO" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Cleanup.prepare(Memory, store, :pre_release)
    assert {:ok, pending} = Cleanup.accept(Memory, store, parent, child, child.version, 1401)
    source = Cleanup.fetch(Memory, store, parent)
    common = NativePartialBranchDisposalContract.result(pending, metadata, "resolved_absent")
    refute NativePartialBranchDisposalResult.bound?(common, source, pending)
    assert {:error, _} = Cleanup.resolve(Memory, store, source, pending, common, 1402)
    assert {:error, _} = PublicDisposal.run(nil, nil, pending, pending.version)
    assert Cleanup.fetch(Memory, store, child) == pending
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "wrong typed proofs source observations and result versions leave both records and usage intact" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Cleanup.prepare(Memory, store, :explicit_release)
    assert {:ok, pending} = Cleanup.accept(Memory, store, parent, child, child.version, 1401)
    source = Cleanup.fetch(Memory, store, parent)
    result = Cleanup.result(pending, metadata)
    request = Map.put(result.proof.request, "operation_id", "other-valid-cleanup")

    request =
      Map.put(request, "request_sha256", PartialBranchDisposalCleanup.request_digest(request))

    proof = %{result.proof | request: request}

    proof = %{
      proof
      | proof_sha256:
          PartialBranchDisposalCleanup.proof_digest(PartialBranchDisposalCleanup.to_wire(proof))
    }

    assert PartialBranchDisposalCleanup.valid?(proof)

    for wrong <- [
          %{result | version: pending.version + 1},
          %{result | proof: proof},
          %{result | proof: PartialBranchDisposalCleanup.to_wire(result.proof)},
          %{result | source: %{result.source | network: :enabled}},
          put_in(result.source.backend_identity.pid_identity, [999, 999]),
          put_in(
            result.source.backend_identity.receipt["material"]["record_sha256"],
            String.duplicate("f", 64)
          ),
          %{result | proof: Map.put(result.proof, :extra, true)}
        ] do
      refute NativePartialBranchCleanupResult.bound?(wrong, source, pending)
      assert {:error, _} = Cleanup.resolve(Memory, store, source, pending, wrong, 1402)
      assert Cleanup.fetch(Memory, store, parent) == source
      assert Cleanup.fetch(Memory, store, child) == pending
      assert {:ok, ^usage} = Memory.usage(store, source.worker_id)
    end
  end

  test "stale source guards cannot accept or commit cleanup" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Cleanup.prepare(Memory, store, :held)

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1401, 10_000])

    assert {:error, _} = Cleanup.accept(Memory, store, parent, child, child.version, 1402)
    assert {:ok, pending} = Cleanup.accept(Memory, store, current, child, child.version, 1402)

    assert {:error, _} =
             Cleanup.resolve(
               Memory,
               store,
               current,
               pending,
               Cleanup.result(pending, metadata),
               1403
             )

    assert Cleanup.fetch(Memory, store, child) == pending
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "pending and completed actions cannot be removed rewritten or acknowledged independently" do
    {_, completed, pending, _, _} =
      Cleanup.complete(Memory, start_supervised!(Memory), :initial_release)

    for child <- [pending, completed] do
      disposal = child.branch.native_authority.partial_disposal
      authority = child.branch.native_authority

      for cleanup <- [
            nil,
            %{disposal.cleanup | platform: "linux"},
            NativePartialBranchCleanup.new(authority, child.version, "macos")
          ] do
        changed = %{authority | partial_disposal: %{disposal | cleanup: cleanup}}

        assert {:error, _} =
                 ManagedMachine.update(
                   child,
                   %{branch: %{child.branch | native_authority: changed}},
                   1410
                 )
      end

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{branch: %{child.branch | state: :disposal_pending}},
                 1410
               )
    end

    disposal = completed.branch.native_authority.partial_disposal

    for changed <- [
          %{disposal | proof: nil, completion_version: nil},
          %{disposal | cleanup: %{disposal.cleanup | proof: nil, completion_version: nil}}
        ] do
      authority = %{completed.branch.native_authority | partial_disposal: changed}
      refute SmolBox.Embedded.NativePartialBranchDisposal.valid?(changed, authority)
    end
  end

  test "v48 rejects unsupported older tags lost actions compressed trailing oversized and mislabeled histories" do
    store = start_supervised!(Memory)
    {_, completed, pending, _, _} = Cleanup.complete(Memory, store, :held)

    for child <- [pending, completed] do
      assert {:ok, <<"smolbox-record-v48", 0, payload::binary>> = bytes} = Codec.encode(child)
      assert {:ok, ^child} = Codec.decode(bytes)

      for version <- 1..47,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> payload))

      assert {:error, _} = Codec.decode(bytes <> <<0>>)

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v48" <> <<0>> <> :erlang.term_to_binary(child, [:compressed])
               )

      stripped = put_in(child.branch.native_authority.partial_disposal.cleanup, nil)

      assert {:error, _} =
               Codec.decode("smolbox-record-v48" <> <<0>> <> :erlang.term_to_binary(stripped))
    end

    stripped =
      update_in(pending.branch.native_authority.partial_disposal, &Map.delete(&1, :cleanup))

    for version <- 45..47 do
      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v#{version}" <> <<0>> <> :erlang.term_to_binary(stripped)
               )
    end

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v48" <> <<0, 131, 116>> <> :binary.copy(<<0>>, 16_777_216)
             )

    assert {:ok, %{native_partial_branch_cleanups: 1} = caps} = Memory.capabilities(store)
    assert caps.native_branches == 1
    assert {:error, _} = Branch.validate(%{pending.branch | native_authority: nil})
  end

  test "original v45 omits exactly the nil nested default and future-tag misuse rejects" do
    {parent, pending, _, _} = Cleanup.prepare(Memory, start_supervised!(Memory), :held)
    assert {:ok, <<"smolbox-record-v45", 0, payload::binary>> = bytes} = Codec.encode(pending)
    encoded = :erlang.binary_to_term(payload)
    refute Map.has_key?(encoded.branch.native_authority.partial_disposal, :cleanup)
    assert {:ok, ^pending} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode("smolbox-record-v48" <> <<0>> <> payload)

    assert {:error, _} =
             Codec.decode("smolbox-record-v45" <> <<0>> <> :erlang.term_to_binary(pending))

    assert {:error, _} =
             Codec.decode("smolbox-record-v48" <> <<0>> <> :erlang.term_to_binary(parent))
  end

  test "fresh normal readers load the nested pending and completed proof without prior atom warmup" do
    {_, completed, pending, _, _} = Cleanup.complete(Memory, start_supervised!(Memory), :held)

    for child <- [pending, completed] do
      {:ok, bytes} = Codec.encode(child)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-partial-cleanup-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[p] = System.argv(); case p |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{partial_disposal: %{cleanup: %{request: %{"quiesced" => true}}}}}}} -> IO.puts("fresh-cleanup"); _ -> System.halt(1) end/

      assert {"fresh-cleanup\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end

  test "retirement and backing closure preserve the complete cleanup acknowledgement and v48 history" do
    store = start_supervised!(Memory)
    {parent, child, _, _, _} = Cleanup.complete(Memory, store, :held)
    saved = child.branch.native_authority.partial_disposal
    proof = NativePartialBranchRetirementContract.proof(child)

    assert {:ok, retired} =
             NativePartialBranchRetirementContract.advance(
               Memory,
               store,
               parent,
               child,
               proof,
               1500
             )

    parent = Cleanup.fetch(Memory, store, parent)

    assert {:ok, deleting} =
             Memory.machine(store, :request, [
               ManagedMachine.key(parent),
               :delete,
               parent.version,
               1501
             ])

    assert {:ok, source} =
             Memory.machine(store, :write, [
               ManagedMachine.key(parent),
               Contract.guard(deleting),
               [
                 state: :deleted,
                 operation: nil,
                 phase: nil,
                 operation_deadline_ms: nil,
                 absence_at_ms: 1502
               ],
               1502
             ])

    assert {:ok, pending} =
             NativePartialBranchBackingContract.accept(Memory, store, source, retired, 1503)

    source = Cleanup.fetch(Memory, store, source)

    backing =
      NativePartialBranchBackingContract.proof(pending.branch.native_authority.backing.request)

    assert {:ok, closed} =
             NativePartialBranchBackingContract.complete_proof(
               Memory,
               store,
               source,
               pending,
               backing,
               1504
             )

    for record <- [retired, pending, closed] do
      assert record.branch.native_authority.partial_disposal == saved
      assert {:ok, <<"smolbox-record-v48", 0, _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    assert {:ok, %{slots: 0, cpus: 0, memory_mb: 0, disk_gb: 0}} =
             Memory.usage(store, parent.worker_id)
  end
end
