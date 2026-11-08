defmodule SmolBox.NativePartialBranchCollectionTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedMachine, Store}
  alias SmolBox.Store.{Codec, Memory, NativePartialBranchCollectionContract}

  alias NativePartialBranchCollectionContract, as: Contract

  for hold <- [true, false] do
    test "held=#{hold} accepted intent and proof preserve uncertain creation and every reservation" do
      Contract.complete(Memory, start_supervised!(Memory), unquote(hold))
    end
  end

  test "stale result cannot complete after a child version change and exact accepted request survives" do
    store = start_supervised!(Memory)
    {parent, child, _, usage} = Contract.prepare(Memory, store, true)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(pending)

    assert {:ok, fresh} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1104, 10_000])

    assert {:error, _} = Contract.finish(Memory, store, parent, fresh, result, 1105)
    assert Contract.fetch(Memory, store, child) == fresh
    assert Contract.fetch(Memory, store, parent) == parent
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, collected} =
             Contract.finish(Memory, store, parent, fresh, Contract.result(fresh), 1105)

    assert collected.branch.native_authority.partial_collection.request ==
             pending.branch.native_authority.partial_collection.request
  end

  test "collection acknowledgement cannot be erased changed or turned into deletion or readiness" do
    {_, child, _, _} = Contract.complete(Memory, start_supervised!(Memory), true)
    saved = child.branch.native_authority.partial_collection

    for replacement <- [
          nil,
          %{saved | proof: nil, completion_version: nil},
          %{saved | platform: "foreign"},
          %{saved | version: saved.version + 1}
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   branch: %{
                     child.branch
                     | native_authority: %{
                         child.branch.native_authority
                         | partial_collection: replacement
                       }
                   }
                 },
                 1110
               )
    end

    for changes <- [
          %{
            state: :deleted,
            reservation: nil,
            operation: nil,
            phase: nil,
            operation_deadline_ms: nil
          },
          %{branch: %{child.branch | state: :ready}}
        ] do
      assert {:error, _} = ManagedMachine.update(child, changes, 1110)
    end
  end

  test "selective v44 and fresh reader retain exact intent and reject older-envelope substitution" do
    {_, completed, _, pending} = Contract.complete(Memory, start_supervised!(Memory), true)

    for child <- [pending, completed] do
      assert {:ok, <<"smolbox-record-v44\0", _::binary>> = bytes} = Codec.encode(child)
      assert {:ok, ^child} = Codec.decode(bytes)
      assert {:error, _} = Codec.decode(bytes <> <<0>>)

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v44\0" <> :erlang.term_to_binary(child, [:compressed])
               )

      for version <- 1..43 do
        assert {:error, _} =
                 Codec.decode("smolbox-record-v#{version}\0" <> :erlang.term_to_binary(child))
      end

      empty = put_in(child.branch.native_authority.partial_collection, nil)
      assert {:error, _} = Codec.decode("smolbox-record-v44\0" <> :erlang.term_to_binary(empty))

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-partial-collection-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{partial_collection: %{request: %{"quiesced" => true}}}}}} -> IO.puts("fresh-partial"); _ -> System.halt(1) end/

      assert {"fresh-partial\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v44\0" <> <<131, 116>> <> :binary.copy(<<0>>, 16_777_216)
             )

    assert {:ok, %{native_partial_branch_collections: 1}} =
             Store.Memory.capabilities(start_supervised!({Memory, []}, id: :other_store))
  end
end
