defmodule SmolBox.NativeBranchDeletionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{NativeBranchDeletion, NativeGrowth}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Contract,
    Memory,
    NativeBranchDeletionContract,
    NativeBranchDeletionOps,
    NativeBranchRetirementContract
  }

  test "accepted intent and exact proof resolve original held deletion while retaining dependency and backing" do
    NativeBranchDeletionContract.complete(Memory, start_supervised!(Memory))
  end

  test "unaccepted and generic uncertain-to-deleted transitions cannot release a native child slot" do
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, start_supervised!(Memory))

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{state: :deleted, operation: nil, phase: nil, reservation: nil},
               1303
             )

    assert {:error, _} = NativeBranchDeletionOps.resolve(child, :absent, 1303)
    assert {:ok, receipt, _, _} = NativeGrowth.head(child)

    request =
      NativeBranchDeletion.intent(
        child.branch.native_authority,
        child.version,
        elem(child.last_request, 1),
        receipt
      )

    assert {:error, _} =
             NativeBranchDeletionOps.resolve(
               child,
               NativeBranchDeletionContract.proof(request),
               1303
             )
  end

  test "accepted request and proof remain immutable through later retirement" do
    store = start_supervised!(Memory)
    {parent, child, proof, _} = NativeBranchDeletionContract.complete(Memory, store)
    saved = child.branch.native_authority.deletion

    for changed <- [
          nil,
          %{saved | proof: nil},
          %{saved | delete_version: saved.delete_version + 1}
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   branch: %{
                     child.branch
                     | native_authority: %{child.branch.native_authority | deletion: changed}
                   }
                 },
                 1307
               )
    end

    assert {:ok, parent} =
             Memory.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1307, 10_000])

    absence = NativeBranchRetirementContract.proof(child)

    assert {:ok, retired} =
             Memory.machine(store, :branch_retire, [
               ManagedMachine.key(parent),
               Contract.guard(parent),
               child.id,
               absence,
               1308
             ])

    assert retired.branch.native_authority.deletion.proof == proof
    NativeBranchDeletionContract.roundtrip(retired)
  end

  test "old native v30 envelopes keep exact bytes and reject even explicit new nil defaults" do
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, start_supervised!(Memory))
    assert {:ok, bytes} = Codec.encode(child)

    old =
      update_in(
        child.branch.native_authority,
        &Map.drop(&1, [
          :collected_publication,
          :partial_collection,
          :partial_disposal,
          :prepared_retirement,
          :disposal,
          :release,
          :retirement,
          :backing,
          :deletion,
          :delete_continuation,
          :delete_cleanup,
          :delete_collection
        ])
      )

    assert bytes ==
             "smolbox-record-v30\0" <>
               :erlang.term_to_binary(update_in(old.branch, &Map.delete(&1, :release_env)))

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v30\0" <>
                 :erlang.term_to_binary(
                   update_in(
                     child.branch.native_authority,
                     &Map.drop(&1, [
                       :release,
                       :retirement,
                       :backing,
                       :delete_continuation,
                       :delete_cleanup,
                       :delete_collection
                     ])
                   )
                 )
             )
  end

  test "fresh BEAM reads pending and completed v34 without native tools" do
    store = start_supervised!(Memory)
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)
    assert {:ok, pending} = NativeBranchDeletionContract.accept(Memory, store, child, 1303)
    proof = NativeBranchDeletionContract.proof(pending.branch.native_authority.deletion.request)
    assert {:ok, gone} = NativeBranchDeletionContract.resolve(Memory, store, pending, proof, 1304)

    for record <- [pending, gone] do
      bytes = NativeBranchDeletionContract.roundtrip(record)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-delete-resolution-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{deletion: %{request: %{"quiesced" => true}}}}}} -> IO.puts("fresh-delete"); _ -> System.halt(1) end/

      assert {"fresh-delete\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end
end
