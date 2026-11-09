defmodule SmolBox.NativePreparedBranchRetirementTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    NativeGrowth,
    NativePreparedBranchRetirement,
    NativePreparedBranchRetirementResult,
    PreparedBranchRetirement
  }

  alias SmolBox.{BranchSpec, CheckpointCaptureSpec, CheckpointPolicy, ManagedMachine}

  alias SmolBox.Store.{
    BranchOps,
    CaptureOps,
    Codec,
    Memory,
    NativeBranchContract,
    NativeBranchDeletionActionContract,
    NativeBranchDeletionContract,
    NativeBranchOps,
    NativePreparedBranchRetirementContract,
    NativePreparedBranchRetirementOps
  }

  for hold <- [true, false] do
    test "held=#{hold} prepared-only retirement atomically retains history without changing material" do
      NativePreparedBranchRetirementContract.complete(
        Memory,
        start_supervised!(Memory),
        unquote(hold)
      )
    end
  end

  test "stopped source observation can release only this unentered declaration" do
    {parent, child, result, _} =
      NativePreparedBranchRetirementContract.prepare(Memory, start_supervised!(Memory), true)

    stopped = %{
      result.source
      | state: :stopped,
        backend_identity: %{result.source.backend_identity | pid_identity: nil}
    }

    assert {:ok, source, retired} =
             NativePreparedBranchRetirementOps.resolve(
               parent,
               child,
               %{result | source: stopped},
               1103
             )

    assert source.state == :stopped and source.observed_machine == stopped
    assert retired.branch.native_authority.prepared_retirement.proof == result.proof
  end

  test "fresh child claim fences an in-flight proof without releasing any charge" do
    store = start_supervised!(Memory)

    {parent, child, result, usage} =
      NativePreparedBranchRetirementContract.prepare(Memory, store, true)

    assert {:ok, fresh} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1103, 10_000])

    assert {:error, _} =
             NativePreparedBranchRetirementContract.resolve(
               Memory,
               store,
               parent,
               child,
               result,
               1104
             )

    assert NativePreparedBranchRetirementContract.fetch(Memory, store, parent) == parent
    assert NativePreparedBranchRetirementContract.fetch(Memory, store, child) == fresh
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativePreparedBranchRetirementContract.resolve(
               Memory,
               store,
               parent,
               fresh,
               %{result | version: fresh.version},
               1104
             )
  end

  test "proof history cannot be removed, rebound, reopened or converted into completion/backing evidence" do
    {source, child, result, _} =
      NativePreparedBranchRetirementContract.complete(Memory, start_supervised!(Memory), false)

    saved = child.branch.native_authority.prepared_retirement
    refute inspect(saved) =~ saved.request["creation"]["source"]["owner_token"]

    for authority <- [
          %{child.branch.native_authority | prepared_retirement: nil},
          %{
            child.branch.native_authority
            | prepared_retirement: %{saved | version: child.version}
          },
          put_in(
            child.branch.native_authority.request["initial_release"]["operation_id"],
            "changed"
          )
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{branch: %{child.branch | native_authority: authority}},
                 1200
               )
    end

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{branch: %{child.branch | state: :resolved, retired_at_ms: nil}},
               1200
             )

    assert {:error, _} = ManagedMachine.update(source, %{native_branch_history: %{}}, 1200)
    assert {:error, _} = Codec.encode(%{source | branch_children: %{child.id => false}})
    assert {:error, _} = Codec.encode(put_in(source.native_branch_history[child.id].proof, nil))
    refute NativePreparedBranchRetirementResult.bound?(result, source, child)
  end

  test "wrong native process, plan, source material or child cannot be rebound with outer hashes" do
    {parent, child, result, _} =
      NativePreparedBranchRetirementContract.prepare(Memory, start_supervised!(Memory), false)

    request = NativePreparedBranchRetirement.request(child.branch.native_authority)

    for invalid <- [
          put_in(result.source.backend_identity.receipt["material"]["revision"], 1),
          put_in(result.proof.retirement["intent"]["source_pid"], [999, 999]),
          put_in(result.proof.retirement["intent"]["plan"]["ordinary_child"]["disk_gb"], 99),
          put_in(result.proof.retirement["intent"]["child"]["name"], "other")
        ] do
      assert {:error, _} = NativePreparedBranchRetirementOps.resolve(parent, child, invalid, 1103)
    end

    intent = result.proof.retirement["intent"]
    # Independently valid inner/outer hashes cannot replace the original PID or plan.
    cpu_plan =
      intent["plan"] |> put_in(~w(ordinary_child cpus), 2) |> put_in(~w(total_additional cpus), 3)

    for changed <- [Map.put(intent, "source_pid", [999, 999]), Map.put(intent, "plan", cpu_plan)] do
      changed = NativePreparedBranchRetirementContract.rehash_intent(changed)
      rebound = NativePreparedBranchRetirementContract.proof(changed, request)
      assert PreparedBranchRetirement.valid?(rebound)

      assert {:error, _} =
               NativePreparedBranchRetirementOps.resolve(
                 parent,
                 child,
                 %{result | proof: rebound},
                 1103
               )
    end

    proof = %{
      result.proof
      | proof_sha256:
          PreparedBranchRetirement.proof_digest(PreparedBranchRetirement.to_wire(result.proof))
    }

    assert {:ok, _, _} =
             NativePreparedBranchRetirementOps.resolve(
               parent,
               child,
               %{result | proof: proof},
               1103
             )
  end

  test "retired creation IDs remain unavailable to captures while unrelated capture admission works" do
    {source, child, _, usage} =
      NativePreparedBranchRetirementContract.complete(Memory, start_supervised!(Memory), true)

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "prepared-history",
        root: "/operator/captures",
        max_bytes: 1_048_576,
        resources: %{slots: 1, cpus: 1, memory_mb: 384, disk_gb: 16}
      )

    {:ok, spec} = CheckpointCaptureSpec.new(id: child.id, policy: policy, idle: true)
    capacity = %{slots: 16, cpus: 32, memory_mb: 65_536, disk_gb: 1024}

    fingerprint =
      CheckpointCaptureSpec.fingerprint(
        spec,
        ManagedMachine.key(source),
        String.duplicate("k", 32)
      )

    assert {:error, _} =
             CaptureOps.accept(source, spec, fingerprint, capacity, usage, 1200)

    assert {:ok, next} =
             CaptureOps.accept(
               source,
               %{spec | id: "another"},
               fingerprint,
               capacity,
               usage,
               1200
             )

    assert next.native_branch_history == source.native_branch_history
    NativePreparedBranchRetirementContract.roundtrip(next)
  end

  test "later sibling publication preserves retirement history without inserting a material link" do
    {source, retired, _, usage} =
      NativePreparedBranchRetirementContract.complete(Memory, start_supervised!(Memory), true)

    spec = %{retired.branch.spec | id: "later"}

    fingerprint =
      BranchSpec.fingerprint(spec, ManagedMachine.key(source), String.duplicate("k", 32))

    capacity = %{slots: 16, cpus: 32, memory_mb: 65_536, disk_gb: 1024}

    assert {:ok, parent, child} =
             NativeBranchOps.accept(
               source,
               spec,
               fingerprint,
               "owned-later",
               capacity,
               usage,
               1200
             )

    result = NativeBranchContract.result(parent, child)
    assert {:ok, parent, child} = BranchOps.advance(parent, child, :accepted, :dispatching, 1201)
    assert {:ok, parent, child} = NativeBranchOps.complete(parent, child, result, 1202)
    assert parent.native_branch_history[retired.id] == source.native_branch_history[retired.id]
    assert {:ok, [publication]} = NativeGrowth.transitions(parent)
    assert parent.native_branch_history[child.id] == publication
    assert publication.previous == source.observed_machine.backend_identity.receipt
    NativePreparedBranchRetirementContract.roundtrip(parent)
  end

  test "v35 bytes omit only the new nil default and a fresh BEAM reads both v36 records without Rust" do
    store = start_supervised!(Memory)
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)

    assert {:ok, child} =
             NativeBranchDeletionActionContract.accept(Memory, store, child, :continue, 1303)

    assert {:ok, bytes} = Codec.encode(child)

    old =
      update_in(
        child.branch.native_authority,
        &(&1
          |> Map.delete(:prepared_retirement)
          |> Map.delete(:disposal)
          |> Map.delete(:delete_collection))
      )

    assert bytes == "smolbox-record-v35\0" <> :erlang.term_to_binary(old)
    assert {:ok, ^child} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode("smolbox-record-v35\0" <> :erlang.term_to_binary(child))
    stop_supervised!(Memory)

    {source, retired, _, _} =
      NativePreparedBranchRetirementContract.complete(Memory, start_supervised!(Memory), true)

    for record <- [source, retired] do
      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-prepared-retirement-#{System.unique_integer([:positive])}"
        )

      File.write!(path, NativePreparedBranchRetirementContract.roundtrip(record), [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, record} -> if SmolBox.ManagedMachine.validate(record) == :ok, do: IO.puts("fresh-prepared-retirement"), else: System.halt(1); _ -> System.halt(1) end/

      assert {"fresh-prepared-retirement\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end
end
