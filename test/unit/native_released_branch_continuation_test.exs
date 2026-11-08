defmodule SmolBox.NativeReleasedBranchContinuationTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    NativeBranchDeletionAction,
    NativeGrowth,
    NativeReleasedBranchDeletionContinuation
  }

  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    CodecNativePreparedBranchRetirements,
    Contract,
    Memory,
    NativeBranchDeletionActionOps,
    NativeBranchDeletionContract,
    NativeBranchRetirementContract,
    NativeReleasedBranchContinuationContract,
    NativeReleasedBranchDeletionContract
  }

  for mode <- [:ready, :released] do
    test "#{mode} accepted continuation retains the exact grant proof and backing" do
      NativeReleasedBranchContinuationContract.complete(
        Memory,
        start_supervised!(Memory),
        unquote(mode)
      )
    end

    test "#{mode} unaccepted continuation and generic deletion cannot release the child slot" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store, unquote(mode))
      assert {:ok, receipt, _, _} = NativeGrowth.head(child)

      request =
        NativeReleasedBranchDeletionContinuation.intent(
          child.branch.native_authority,
          :continue,
          child.version,
          elem(child.last_request, 1),
          receipt
        )

      proof = NativeReleasedBranchContinuationContract.proof(request)
      assert {:error, _} = NativeBranchDeletionActionOps.complete(child, :continue, proof, 1303)

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{state: :deleted, operation: nil, phase: nil, reservation: nil},
                 1303
               )

      assert {:ok, _} = NativeBranchDeletionActionOps.accept(child, :cleanup, 1303)
      assert NativeBranchDeletionAction.eligible?(child, :cleanup)
    end

    for route <- [:continue, :resolve] do
      test "#{mode} #{route} completion preserves the other accepted grant without converting absence into SDK success" do
        NativeReleasedBranchContinuationContract.interleaved(
          Memory,
          start_supervised!(Memory),
          unquote(mode),
          unquote(route)
        )
      end
    end

    test "#{mode} saved history is immutable and retained by independent dependency retirement" do
      store = start_supervised!(Memory)

      {parent, gone, proof, _} =
        NativeReleasedBranchContinuationContract.complete(Memory, store, unquote(mode))

      saved = gone.branch.native_authority.delete_continuation

      for changed <- [
            nil,
            %{saved | proof: nil},
            %{saved | delete_version: saved.delete_version + 1}
          ] do
        assert {:error, _} =
                 ManagedMachine.update(
                   gone,
                   %{
                     branch: %{
                       gone.branch
                       | native_authority: %{
                           gone.branch.native_authority
                           | delete_continuation: changed
                         }
                     }
                   },
                   1307
                 )
      end

      assert {:ok, parent} =
               Memory.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1307, 10_000])

      assert {:ok, retired} =
               Memory.machine(store, :branch_retire, [
                 ManagedMachine.key(parent),
                 Contract.guard(parent),
                 gone.id,
                 NativeBranchRetirementContract.proof(gone),
                 1308
               ])

      assert retired.branch.native_authority.delete_continuation.proof == proof
      NativeReleasedBranchContinuationContract.roundtrip(retired)
    end

    test "#{mode} old v40 and stripped v35 payloads cannot carry a released continuation" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store, unquote(mode))

      assert {:ok, observed} =
               NativeReleasedBranchDeletionContract.accept(Memory, store, child, 1303)

      assert {:ok, before} = Codec.encode(observed)

      assert {:ok, pending} =
               NativeReleasedBranchContinuationContract.accept(
                 Memory,
                 store,
                 observed,
                 :continue,
                 1304
               )

      assert {:ok, ^before} = Codec.encode(observed)

      assert {:error, _} =
               Codec.decode("smolbox-record-v41\0" <> :erlang.term_to_binary(observed))

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v35\0" <>
                   :erlang.term_to_binary(CodecNativePreparedBranchRetirements.strip(pending))
               )

      NativeReleasedBranchContinuationContract.roundtrip(pending)
    end

    test "#{mode} fresh BEAM safely loads pending and completed v41 vocabulary" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store, unquote(mode))

      assert {:ok, pending} =
               NativeReleasedBranchContinuationContract.accept(
                 Memory,
                 store,
                 child,
                 :continue,
                 1303
               )

      proof =
        NativeReleasedBranchContinuationContract.proof(
          pending.branch.native_authority.delete_continuation.request
        )

      assert {:ok, gone} =
               NativeReleasedBranchContinuationContract.finish(
                 Memory,
                 store,
                 pending,
                 :continue,
                 proof,
                 1304
               )

      for record <- [pending, gone] do
        bytes = NativeReleasedBranchContinuationContract.roundtrip(record)

        path =
          Path.join(
            System.tmp_dir!(),
            "smolbox-released-continuation-#{System.unique_integer([:positive])}"
          )

        File.write!(path, bytes, [:exclusive])
        File.chmod!(path, 0o600)
        on_exit(fn -> File.rm(path) end)
        paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

        code =
          ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{delete_continuation: %{request: %{"release" => %{"schema" => 1}}}}}}} -> IO.puts("fresh-released-continuation"); _ -> System.halt(1) end/

        assert {"fresh-released-continuation\n", 0} =
                 System.cmd(
                   System.find_executable("elixir"),
                   Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                   stderr_to_stdout: true
                 )
      end
    end
  end
end
