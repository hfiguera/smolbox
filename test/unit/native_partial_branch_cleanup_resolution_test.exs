defmodule SmolBox.NativePartialBranchCleanupResolutionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    NativePartialBranchCleanup,
    NativePartialBranchDisposal,
    PartialBranchDisposalCleanup,
    PartialBranchDisposalCleanupUnneeded
  }

  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativePartialBranchCleanupContract,
    NativePartialBranchCleanupResolutionContract
  }

  alias NativePartialBranchCleanupResolutionContract, as: Resolution

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ["deleted", "resolved_absent"] do
    test "#{mode} #{provenance} records unnecessary cleanup separately and releases only ordinary capacity" do
      Resolution.complete(Memory, start_supervised!(Memory), unquote(mode), unquote(provenance))
    end
  end

  test "crossed requests stale observations and swapped typed acknowledgements cannot change either record or usage" do
    Resolution.reject_crossed(Memory, start_supervised!(Memory))
  end

  test "claims keep the accepted action and require the current child version" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Resolution.prepare(Memory, store, :held)
    assert {:ok, pending} = Resolution.accept(Memory, store, parent, child, child.version, 1401)
    source = Resolution.fetch(Memory, store, parent)
    result = Resolution.result(pending, metadata, "deleted")

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1402, 10_000])

    saved = pending.branch.native_authority.partial_disposal.cleanup
    assert current.branch.native_authority.partial_disposal.cleanup == saved

    assert {:ok, ^current} =
             Resolution.accept(Memory, store, source, current, saved.version, 1403)

    assert {:error, _} = Resolution.resolve(Memory, store, source, current, result, 1404)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, completed} =
             Resolution.resolve(
               Memory,
               store,
               source,
               current,
               %{result | version: current.version},
               1404
             )

    source = Resolution.fetch(Memory, store, parent)

    assert {:error, _} =
             Resolution.resolve(
               Memory,
               store,
               source,
               completed,
               %{result | version: completed.version},
               1405
             )

    assert Resolution.fetch(Memory, store, child) == completed
  end

  test "completion cannot remove change relabel or independently clear the cleanup acknowledgement" do
    {_, child, _, result, _} =
      Resolution.complete(Memory, start_supervised!(Memory), :initial_release, "resolved_absent")

    saved = child.branch.native_authority.partial_disposal
    wire = PartialBranchDisposalCleanupUnneeded.to_wire(result.proof)

    assert {:ok, removal} =
             PartialBranchDisposalCleanup.from_wire(
               Map.put(wire, "proof_sha256", PartialBranchDisposalCleanup.proof_digest(wire))
             )

    for cleanup <- [
          nil,
          %{saved.cleanup | unneeded: nil},
          %{saved.cleanup | proof: removal},
          %{saved.cleanup | proof: removal, unneeded: nil},
          %{saved.cleanup | completion_version: nil},
          NativePartialBranchCleanup.new(child.branch.native_authority, child.version, "macos")
        ] do
      changed = %{saved | cleanup: cleanup}
      authority = %{child.branch.native_authority | partial_disposal: changed}

      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{branch: %{child.branch | native_authority: authority}},
                 1500
               )
    end

    for cleanup <- [
          %{saved.cleanup | unneeded: nil},
          %{saved.cleanup | proof: removal},
          %{saved.cleanup | completion_version: nil}
        ] do
      changed = %{saved | cleanup: cleanup}

      refute NativePartialBranchDisposal.valid?(changed, %{
               child.branch.native_authority
               | partial_disposal: changed
             })
    end
  end

  test "v49 rejects every older tag compressed trailing oversized stripped and crossed histories" do
    {_, child, pending, _, _} =
      Resolution.complete(Memory, start_supervised!(Memory), :held, "deleted")

    assert {:ok, <<"smolbox-record-v49", 0, payload::binary>> = bytes} = Codec.encode(child)

    old = update_in(child.branch.native_authority, &Map.delete(&1, :collected_publication))

    assert bytes ==
             "smolbox-record-v49" <>
               <<0>> <>
               :erlang.term_to_binary(update_in(old.branch, &Map.delete(&1, :release_env)))

    for version <- 1..48,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> payload))

    assert {:error, _} = Codec.decode(bytes <> <<0>>)

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v49" <> <<0>> <> :erlang.term_to_binary(child, [:compressed])
             )

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v49" <> <<0, 131, 116>> <> :binary.copy(<<0>>, 16_777_216)
             )

    stripped = put_in(child.branch.native_authority.partial_disposal.cleanup.unneeded, nil)

    assert {:error, _} =
             Codec.decode("smolbox-record-v49" <> <<0>> <> :erlang.term_to_binary(stripped))

    assert {:ok, <<"smolbox-record-v48", 0, old::binary>>} = Codec.encode(pending)
    assert {:error, _} = Codec.decode("smolbox-record-v49" <> <<0>> <> old)
  end

  test "v48 pending and removal records omit exactly the new nil default and preserve old terms" do
    {_, completed, pending, _, _} =
      NativePartialBranchCleanupContract.complete(Memory, start_supervised!(Memory), :held)

    for record <- [pending, completed] do
      assert {:ok, <<"smolbox-record-v48", 0, payload::binary>> = bytes} = Codec.encode(record)

      expected =
        update_in(
          record.branch.native_authority.partial_disposal.cleanup,
          &Map.delete(&1, :unneeded)
        )

      old = update_in(expected.branch.native_authority, &Map.delete(&1, :collected_publication))

      assert :erlang.binary_to_term(payload) ==
               update_in(old.branch, &Map.delete(&1, :release_env))

      assert {:ok, ^record} = Codec.decode(bytes)

      assert {:error, _} =
               Codec.decode("smolbox-record-v48" <> <<0>> <> :erlang.term_to_binary(record))

      assert {:error, _} = Codec.decode("smolbox-record-v49" <> <<0>> <> payload)
    end

    assert {:ok, %{native_partial_branch_cleanup_resolutions: 1} = caps} =
             Memory.capabilities(start_supervised!(Memory, id: :marker))

    assert caps.native_branches == 1
  end

  test "fresh normal BEAM readers load v49 without native assets or atom warmup" do
    {_, child, _, _, _} =
      Resolution.complete(Memory, start_supervised!(Memory), :explicit_release, "deleted")

    {:ok, bytes} = Codec.encode(child)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-cleanup-unneeded-#{System.unique_integer([:positive])}"
      )

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code =
      ~S/[p] = System.argv(); case p |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{partial_disposal: %{cleanup: %{proof: nil, unneeded: ack}}}}}} -> if Atom.to_string(Map.fetch!(ack, :__struct__)) == "Elixir.SmolBox.Embedded.PartialBranchDisposalCleanupUnneeded", do: IO.puts("fresh-unneeded"), else: System.halt(1); _ -> System.halt(1) end/

    assert {"fresh-unneeded\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "retirement and backing closure preserve separate unneeded history until all accounting closes" do
    store = start_supervised!(Memory)
    {parent, child, _, _, _} = Resolution.complete(Memory, store, :held, "resolved_absent")
    Resolution.close_storage(Memory, store, parent, child)
  end
end
