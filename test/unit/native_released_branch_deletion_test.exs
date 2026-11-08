defmodule SmolBox.NativeReleasedBranchDeletionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    BranchDeletionResolution,
    NativeBranchDeletion,
    NativeGrowth,
    NativeReleasedBranchDeletion
  }

  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Contract,
    Memory,
    NativeBranchDeletionContract,
    NativeBranchRetirementContract,
    NativeReleasedBranchDeletionContract
  }

  for mode <- [:ready, :released] do
    test "#{mode} preexisting envelopes stay exact and cannot be relabeled as released deletion" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeReleasedBranchDeletionContract.prepare(Memory, store, unquote(mode))
      assert {:ok, bytes} = Codec.encode(child)
      [prefix, payload] = :binary.split(bytes, <<0>>)

      assert prefix ==
               if(unquote(mode) == :ready, do: "smolbox-record-v30", else: "smolbox-record-v31")

      assert {:ok, ^child} = Codec.decode(bytes)
      assert {:error, _} = Codec.decode("smolbox-record-v40\0" <> payload)
      assert {:ok, _} = NativeReleasedBranchDeletionContract.accept(Memory, store, child, 1303)
      assert {:ok, ^bytes} = Codec.encode(child)
    end

    test "#{mode} accepted released deletion resolves with exact proof and preserves source backing" do
      NativeReleasedBranchDeletionContract.complete(
        Memory,
        start_supervised!(Memory),
        unquote(mode)
      )
    end

    test "#{mode} generic absence held proofs and unaccepted grants cannot release the child" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.denied_released(Memory, store, unquote(mode))
      assert NativeBranchDeletion.required?(child)
      refute NativeBranchDeletion.eligible?(child)
      assert NativeReleasedBranchDeletion.eligible?(child)
      assert NativeBranchDeletion.resolvable?(child)
      assert {:ok, receipt, _, _} = NativeGrowth.head(child)

      request =
        NativeReleasedBranchDeletion.intent(
          child.branch.native_authority,
          child.version,
          elem(child.last_request, 1),
          receipt
        )

      proof = NativeReleasedBranchDeletionContract.proof(request)

      assert {:error, _} =
               NativeReleasedBranchDeletionContract.resolve(Memory, store, child, proof, 1303)

      assert {:ok, pending} =
               NativeReleasedBranchDeletionContract.accept(Memory, store, child, 1303)

      saved = pending.branch.native_authority.deletion
      refute NativeBranchDeletion.matches?(saved, hd(held_proofs()))

      assert {:error, _} =
               NativeReleasedBranchDeletionContract.resolve(
                 Memory,
                 store,
                 pending,
                 hd(held_proofs()),
                 1304
               )

      assert NativeReleasedBranchDeletionContract.fetch(Memory, store, pending) == pending
    end

    test "#{mode} accepted released request is immutable after completion and dependency retirement" do
      store = start_supervised!(Memory)

      {parent, child, proof, _} =
        NativeReleasedBranchDeletionContract.complete(Memory, store, unquote(mode))

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
      NativeReleasedBranchDeletionContract.roundtrip(retired)
    end

    test "#{mode} fresh BEAM reads pending and completed v40 without native tools" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeReleasedBranchDeletionContract.prepare(Memory, store, unquote(mode))

      assert {:ok, pending} =
               NativeReleasedBranchDeletionContract.accept(Memory, store, child, 1303)

      proof =
        NativeReleasedBranchDeletionContract.proof(
          pending.branch.native_authority.deletion.request
        )

      assert {:ok, gone} =
               NativeReleasedBranchDeletionContract.resolve(Memory, store, pending, proof, 1304)

      for record <- [pending, gone] do
        bytes = NativeReleasedBranchDeletionContract.roundtrip(record)

        path =
          Path.join(
            System.tmp_dir!(),
            "smolbox-released-delete-#{System.unique_integer([:positive])}"
          )

        File.write!(path, bytes, [:exclusive])
        File.chmod!(path, 0o600)
        on_exit(fn -> File.rm(path) end)
        paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

        code =
          ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{deletion: %{request: %{"release" => %{"schema" => 1}}}}}}} -> IO.puts("fresh-released-delete"); _ -> System.halt(1) end/

        assert {"fresh-released-delete\n", 0} =
                 System.cmd(
                   System.find_executable("elixir"),
                   Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                   stderr_to_stdout: true
                 )
      end
    end
  end

  defp held_proofs do
    Path.expand("../../native/smolbox-protocol/fixtures/held-branch-deletion-v1.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn row ->
      {:ok, proof} = BranchDeletionResolution.from_wire(row["proof"])
      proof
    end)
  end
end
