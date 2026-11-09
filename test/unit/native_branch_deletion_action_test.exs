defmodule SmolBox.NativeBranchDeletionActionTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{NativeBranchDeletionAction, NativeGrowth}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Contract,
    Memory,
    NativeBranchDeletionActionContract,
    NativeBranchDeletionActionOps,
    NativeBranchDeletionContract,
    NativeBranchRetirementContract
  }

  for action <- [:continue, :cleanup] do
    test "#{action} acceptance retains the exact request and acknowledgement without releasing backing" do
      NativeBranchDeletionActionContract.complete(
        Memory,
        start_supervised!(Memory),
        unquote(action)
      )
    end
  end

  test "unaccepted acknowledgements and generic writes cannot finish an original held deletion" do
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, start_supervised!(Memory))
    assert {:ok, receipt, _, _} = NativeGrowth.head(child)

    for action <- [:continue, :cleanup] do
      request =
        NativeBranchDeletionAction.intent(
          child.branch.native_authority,
          action,
          child.version,
          elem(child.last_request, 1),
          receipt
        )

      proof = NativeBranchDeletionActionContract.proof(request)
      assert {:error, _} = NativeBranchDeletionActionOps.complete(child, action, proof, 1303)

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{state: :deleted, operation: nil, phase: nil, reservation: nil},
                 1303
               )
    end

    assert {:error, _} = NativeBranchDeletionActionOps.accept(child, :delete, 1303)
    assert {:error, _} = NativeBranchDeletionActionOps.complete(child, :delete, :absent, 1303)
  end

  test "cleanup acknowledgement preserves earlier uncertain continuation and observational requests" do
    store = start_supervised!(Memory)
    {parent, child, usage} = NativeBranchDeletionContract.prepare(Memory, store)

    assert {:ok, child} =
             NativeBranchDeletionActionContract.accept(Memory, store, child, :continue, 1303)

    continued = child.branch.native_authority.delete_continuation
    assert {:ok, child} = NativeBranchDeletionContract.accept(Memory, store, child, 1304)
    observed = child.branch.native_authority.deletion

    assert {:ok, child} =
             NativeBranchDeletionActionContract.accept(Memory, store, child, :cleanup, 1305)

    cleanup = child.branch.native_authority.delete_cleanup
    refute cleanup.request["request_sha256"] == continued.request["request_sha256"]
    refute cleanup.request["request_sha256"] == observed.request["request_sha256"]
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    proof = NativeBranchDeletionActionContract.proof(cleanup.request)

    assert {:ok, gone} =
             NativeBranchDeletionActionContract.finish(
               Memory,
               store,
               child,
               :cleanup,
               proof,
               1306
             )

    assert gone.branch.native_authority.delete_continuation == continued
    assert gone.branch.native_authority.deletion == observed
    assert gone.branch.native_authority.delete_cleanup.proof == proof
    assert :ok = ManagedMachine.validate(gone)

    assert {:error, _} =
             NativeBranchDeletionActionContract.finish(
               Memory,
               store,
               gone,
               :continue,
               NativeBranchDeletionActionContract.proof(continued.request),
               1307
             )

    NativeBranchDeletionActionContract.roundtrip(gone)
  end

  for route <- [:continue, :resolve] do
    test "#{route} completion preserves a different pending cleanup request" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)

      assert {:ok, child} =
               NativeBranchDeletionActionContract.accept(Memory, store, child, :cleanup, 1303)

      cleanup = child.branch.native_authority.delete_cleanup

      gone =
        case unquote(route) do
          :continue ->
            assert {:ok, child} = NativeBranchDeletionContract.accept(Memory, store, child, 1304)
            observed = child.branch.native_authority.deletion

            assert {:ok, child} =
                     NativeBranchDeletionActionContract.accept(
                       Memory,
                       store,
                       child,
                       :continue,
                       1305
                     )

            proof =
              NativeBranchDeletionActionContract.proof(
                child.branch.native_authority.delete_continuation.request
              )

            assert {:ok, child} =
                     NativeBranchDeletionActionContract.finish(
                       Memory,
                       store,
                       child,
                       :continue,
                       proof,
                       1306
                     )

            assert child.branch.native_authority.deletion == observed
            child

          :resolve ->
            assert {:ok, child} = NativeBranchDeletionContract.accept(Memory, store, child, 1304)

            proof =
              NativeBranchDeletionContract.proof(child.branch.native_authority.deletion.request)

            assert {:ok, child} =
                     NativeBranchDeletionContract.resolve(Memory, store, child, proof, 1305)

            child
        end

      assert gone.branch.native_authority.delete_cleanup == cleanup
      assert :ok = ManagedMachine.validate(gone)
      NativeBranchDeletionActionContract.roundtrip(gone)
    end
  end

  test "accepted action history and proof cannot be removed or replaced and survive retirement" do
    store = start_supervised!(Memory)

    {parent, gone, proof, _} =
      NativeBranchDeletionActionContract.complete(Memory, store, :continue)

    saved = gone.branch.native_authority.delete_continuation

    for replacement <- [
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
                         | delete_continuation: replacement
                       }
                   }
                 },
                 1307
               )
    end

    assert {:ok, parent} =
             Memory.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1307, 10_000])

    absence = NativeBranchRetirementContract.proof(gone)

    assert {:ok, retired} =
             Memory.machine(store, :branch_retire, [
               ManagedMachine.key(parent),
               Contract.guard(parent),
               gone.id,
               absence,
               1308
             ])

    assert retired.branch.native_authority.delete_continuation.proof == proof
    NativeBranchDeletionActionContract.roundtrip(retired)
  end

  test "v34 exact bytes omit new defaults and reject even explicit new nil fields" do
    store = start_supervised!(Memory)
    {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)
    assert {:ok, child} = NativeBranchDeletionContract.accept(Memory, store, child, 1303)

    old =
      update_in(
        child.branch.native_authority,
        &Map.drop(&1, [
          :delete_collection,
          :delete_continuation,
          :delete_cleanup,
          :prepared_retirement,
          :disposal
        ])
      )

    assert {:ok, bytes} = Codec.encode(child)
    assert bytes == "smolbox-record-v34\0" <> :erlang.term_to_binary(old)
    assert {:ok, ^child} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode("smolbox-record-v34\0" <> :erlang.term_to_binary(child))
  end

  for action <- [:continue, :cleanup] do
    test "a fresh BEAM reads pending and completed v35 #{action} history without native tools" do
      action = unquote(action)
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store)

      assert {:ok, pending} =
               NativeBranchDeletionActionContract.accept(Memory, store, child, action, 1303)

      proof =
        NativeBranchDeletionActionContract.proof(
          NativeBranchDeletionActionContract.saved(pending, action).request
        )

      assert {:ok, gone} =
               NativeBranchDeletionActionContract.finish(
                 Memory,
                 store,
                 pending,
                 action,
                 proof,
                 1304
               )

      for record <- [pending, gone] do
        bytes = NativeBranchDeletionActionContract.roundtrip(record)

        path =
          Path.join(
            System.tmp_dir!(),
            "smolbox-delete-action-#{System.unique_integer([:positive])}"
          )

        File.write!(path, bytes, [:exclusive])
        File.chmod!(path, 0o600)
        on_exit(fn -> File.rm(path) end)
        paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

        code =
          ~S/[path, kind] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: authority}}} -> slot = if kind == "continue", do: :delete_continuation, else: :delete_cleanup; case Map.fetch!(authority, slot) do %{request: %{"action" => ^kind}} -> IO.puts("fresh-action"); _ -> System.halt(1) end; _ -> System.halt(1) end/

        assert {"fresh-action\n", 0} =
                 System.cmd(
                   System.find_executable("elixir"),
                   Enum.flat_map(paths, &["-pa", &1]) ++
                     ["-e", code, path, Atom.to_string(action)],
                   stderr_to_stdout: true
                 )
      end
    end
  end
end
