defmodule SmolBox.NativeBranchBackingTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{NativeBranchBacking, NativeBranchRetirement}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativeBranchBackingContract,
    NativeBranchBackingOps,
    NativeBranchRetirementContract
  }

  for mode <- [:held, :ready, :released] do
    test "#{mode} request acceptance freezes intent and exact acknowledgement releases only extra backing" do
      NativeBranchBackingContract.completed(Memory, start_supervised!(Memory), unquote(mode))
    end
  end

  test "source must be durably absent with retired dependency and original publication" do
    store = start_supervised!(Memory)
    {source, child, _, _} = NativeBranchRetirementContract.complete(Memory, store, :held)
    assert {:error, _} = NativeBranchBackingOps.accept(source, child, child.version, true, 1312)

    {source, child, _} =
      NativeBranchBackingContract.prepare(
        Memory,
        start_supervised!({Memory, name: nil}, id: :other),
        :held
      )

    for wrong <- [
          %{source | branch_children: %{child.id => false}},
          %{source | native_branch_history: %{}},
          %{source | worker_generation: source.worker_generation + 1}
        ] do
      assert {:error, _} = NativeBranchBackingOps.accept(wrong, child, child.version, true, 1312)
    end

    legacy = put_in(child.branch.native_authority.retirement, nil)
    assert :ok = ManagedMachine.validate(legacy)
    assert {:error, _} = NativeBranchBackingOps.accept(source, legacy, legacy.version, true, 1312)
  end

  test "accepted intent and completed acknowledgement are immutable and older bytes remain exact" do
    {source, child, usage} =
      NativeBranchBackingContract.prepare(Memory, start_supervised!(Memory), :held)

    assert {:ok, bytes} = Codec.encode(child)

    assert bytes ==
             "smolbox-record-v32\0" <>
               :erlang.term_to_binary(
                 update_in(
                   child.branch.native_authority,
                   &(&1
                     |> Map.delete(:backing)
                     |> Map.delete(:deletion)
                     |> Map.delete(:delete_continuation)
                     |> Map.delete(:delete_cleanup)
                     |> Map.delete(:delete_collection)
                     |> Map.delete(:collected_publication)
                     |> Map.delete(:partial_collection)
                     |> Map.delete(:partial_disposal)
                     |> Map.delete(:prepared_retirement)
                     |> Map.delete(:disposal))
                 )
               )

    assert {:error, _} = Codec.decode("smolbox-record-v32\0" <> :erlang.term_to_binary(child))

    assert {:error, _} =
             ManagedMachine.update(child, %{branch: %{child.branch | state: :closed}}, 1312)

    assert {:ok, p, pending} =
             NativeBranchBackingOps.accept(source, child, child.version, true, 1312)

    saved = pending.branch.native_authority.backing

    for changed <- [
          nil,
          %{saved | version: saved.version + 1},
          %{saved | request: Map.put(saved.request, "backing_removed", false)}
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 pending,
                 %{
                   branch: %{
                     pending.branch
                     | native_authority: %{pending.branch.native_authority | backing: changed}
                   }
                 },
                 1313
               )
    end

    proof = NativeBranchBackingContract.proof(saved.request)
    assert {:ok, _, closed} = NativeBranchBackingOps.complete(p, pending, proof, 1313)

    assert {:error, _} =
             ManagedMachine.update(
               closed,
               %{
                 branch: %{
                   closed.branch
                   | native_authority: %{
                       closed.branch.native_authority
                       | backing: %{saved | proof: nil}
                     }
                 }
               },
               1314
             )

    assert closed.branch.native_authority.retirement == child.branch.native_authority.retirement
    assert NativeBranchRetirement.record?(closed) and NativeBranchBacking.record?(closed)
    assert is_map(usage)
  end

  test "fresh BEAM reads both pending and acknowledged v33 without native tools" do
    store = start_supervised!(Memory)
    {source, child, _} = NativeBranchBackingContract.prepare(Memory, store, :released)
    assert {:ok, pending} = NativeBranchBackingContract.accept(Memory, store, source, child, 1312)
    parent = NativeBranchBackingContract.fetch(Memory, store, source)
    proof = NativeBranchBackingContract.proof(pending.branch.native_authority.backing.request)

    assert {:ok, closed} =
             NativeBranchBackingContract.complete_proof(
               Memory,
               store,
               parent,
               pending,
               proof,
               1313
             )

    for record <- [pending, closed] do
      bytes = NativeBranchBackingContract.roundtrip(record)
      path = Path.join(System.tmp_dir!(), "smolbox-backing-#{System.unique_integer([:positive])}")
      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{backing: %{request: %{"backing_removed" => true}}}}}} -> IO.puts("fresh-backing"); _ -> System.halt(1) end/

      assert {"fresh-backing\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end
end
