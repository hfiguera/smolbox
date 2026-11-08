defmodule SmolBox.NativeBranchCollectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.Codec
  alias SmolBox.Store.{Memory, NativeBranchCollectionContract, NativeBranchDeletionContract}

  for mode <- [:held, :ready, :released] do
    test "#{mode} collection retains uncertainty every reservation and exact durable history" do
      NativeBranchCollectionContract.complete(Memory, start_supervised!(Memory), unquote(mode))
    end

    test "#{mode} separate continuation alone releases the ordinary child slot" do
      NativeBranchCollectionContract.continue(Memory, start_supervised!(Memory), unquote(mode))
    end

    test "#{mode} collection request and proof cannot be erased or changed" do
      {_, collected, _, _} =
        NativeBranchCollectionContract.complete(Memory, start_supervised!(Memory), unquote(mode))

      saved = collected.branch.native_authority.delete_collection

      for replacement <- [
            nil,
            %{saved | proof: nil},
            %{saved | delete_version: saved.delete_version + 1}
          ] do
        assert {:error, _} =
                 ManagedMachine.update(
                   collected,
                   %{
                     branch: %{
                       collected.branch
                       | native_authority: %{
                           collected.branch.native_authority
                           | delete_collection: replacement
                         }
                     }
                   },
                   1307
                 )
      end
    end

    for route <- [:continue, :cleanup, :resolve] do
      test "#{mode} #{route} completion preserves an independent pending collection",
        do:
          NativeBranchCollectionContract.interleaved(
            Memory,
            start_supervised!(Memory),
            unquote(mode),
            unquote(route)
          )
    end

    test "#{mode} fresh BEAM loads the new vocabulary without an existing native consumer" do
      store = start_supervised!(Memory)
      {_, child, _} = NativeBranchDeletionContract.prepare(Memory, store, unquote(mode))
      assert {:ok, pending} = NativeBranchCollectionContract.accept(Memory, store, child, 1303)

      evidence =
        NativeBranchCollectionContract.proof(
          pending.branch.native_authority.delete_collection.request
        )

      assert {:ok, completed} =
               NativeBranchCollectionContract.finish(Memory, store, pending, evidence, 1304)

      for record <- [pending, completed] do
        assert {:ok, bytes} = Codec.encode(record)

        path =
          Path.join(
            System.tmp_dir!(),
            "smolbox-original-collection-#{System.unique_integer([:positive])}"
          )

        File.write!(path, bytes, [:exclusive])
        File.chmod!(path, 0o600)
        on_exit(fn -> File.rm(path) end)
        paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

        code =
          ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{delete_collection: %{request: %{"quiesced" => true}}}}}} -> IO.puts("fresh-collection"); _ -> System.halt(1) end/

        assert {"fresh-collection\n", 0} =
                 System.cmd(
                   System.find_executable("elixir"),
                   Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                   stderr_to_stdout: true
                 )
      end
    end
  end
end
