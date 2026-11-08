defmodule SmolBox.NativePartialBranchDisposalTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedMachine, Store}

  alias SmolBox.Embedded.{NativePartialBranchDisposal, NativePartialBranchDisposalResult}

  alias SmolBox.Store.{Codec, Contract, Memory, NativePartialBranchDisposalContract}

  alias NativePartialBranchDisposalContract, as: Disposal

  for mode <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ~w(deleted resolved_absent) do
    test "#{mode} #{provenance} releases only ordinary child capacity and preserves original collection" do
      Disposal.complete(Memory, start_supervised!(Memory), unquote(mode), unquote(provenance))
    end
  end

  test "child claims retain exact frozen disposal but stale results cannot commit" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Disposal.prepare(Memory, store, :held)
    assert {:ok, pending} = Disposal.accept(Memory, store, parent, child, child.version, 1105)
    source = Disposal.fetch(Memory, store, parent)
    result = Disposal.result(pending, metadata)

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1106, 10_000])

    assert {:error, _} = Disposal.resolve(Memory, store, source, current, result, 1107)
    assert Disposal.fetch(Memory, store, child) == current
    assert Disposal.fetch(Memory, store, parent) == source
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert current.branch.native_authority.partial_disposal ==
             pending.branch.native_authority.partial_disposal

    assert {:ok, _} =
             Disposal.resolve(
               Memory,
               store,
               source,
               current,
               %{result | version: current.version},
               1107
             )
  end

  test "missing collection and crossed versions platforms observations or proof preserve both records and usage" do
    store = start_supervised!(Memory)
    {parent, child, metadata, usage} = Disposal.prepare(Memory, store, :pre_release)

    for {version, platform} <- [{child.version - 1, "macos"}, {child.version, "linux"}] do
      assert {:error, _} = Disposal.accept(Memory, store, parent, child, version, 1105, platform)
    end

    authority = child.branch.native_authority

    refute NativePartialBranchDisposal.valid?(
             NativePartialBranchDisposal.new(authority, child.version, "macos"),
             %{authority | partial_collection: nil}
           )

    assert {:ok, pending} = Disposal.accept(Memory, store, parent, child, child.version, 1105)
    source = Disposal.fetch(Memory, store, parent)
    result = Disposal.result(pending, metadata)

    for wrong <- [
          %{result | version: pending.version + 1},
          %{result | source: %{result.source | network: :enabled}},
          put_in(result.source.backend_identity.pid_identity, [999, 999]),
          put_in(
            result.source.backend_identity.receipt["material"]["record_sha256"],
            String.duplicate("f", 64)
          ),
          put_in(result.proof.request["quiesced"], false)
        ] do
      refute NativePartialBranchDisposalResult.bound?(wrong, source, pending)
      assert {:error, _} = Disposal.resolve(Memory, store, source, pending, wrong, 1107)
      assert Disposal.fetch(Memory, store, parent) == source
      assert Disposal.fetch(Memory, store, child) == pending
      assert {:ok, ^usage} = Memory.usage(store, source.worker_id)
    end
  end

  test "completed collection and disposal cannot be erased rewritten readied or converted to backing closure" do
    {_, child, pending, _, _} =
      Disposal.complete(Memory, start_supervised!(Memory), :initial_release, "resolved_absent")

    for record <- [pending, child], field <- [:partial_collection, :partial_disposal] do
      saved = Map.fetch!(record.branch.native_authority, field)

      for changed <- [
            nil,
            %{saved | version: saved.version + 1},
            %{saved | platform: "linux"},
            %{saved | request: Map.put(saved.request, "quiesced", false)}
          ] do
        authority = Map.put(record.branch.native_authority, field, changed)

        assert {:error, _} =
                 ManagedMachine.update(
                   record,
                   %{branch: %{record.branch | native_authority: authority}},
                   1110
                 )
      end

      for state <- [:ready, :closed] do
        assert {:error, _} =
                 ManagedMachine.update(record, %{branch: %{record.branch | state: state}}, 1110)
      end
    end
  end

  test "v45 is selective and rejects older tags compressed trailing oversized or incomplete records" do
    {_, completed, pending, _, _} =
      Disposal.complete(Memory, start_supervised!(Memory), :held, "deleted")

    for child <- [pending, completed] do
      assert {:ok, <<"smolbox-record-v45\0", _::binary>> = bytes} = Codec.encode(child)
      assert {:ok, ^child} = Codec.decode(bytes)
      assert {:error, _} = Codec.decode(bytes <> <<0>>)

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v45\0" <> :erlang.term_to_binary(child, [:compressed])
               )

      for version <- 1..44,
          do:
            assert(
              {:error, _} =
                Codec.decode("smolbox-record-v#{version}\0" <> :erlang.term_to_binary(child))
            )

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v45\0" <>
                   :erlang.term_to_binary(
                     put_in(child.branch.native_authority.partial_disposal, nil)
                   )
               )
    end

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v45\0" <> <<131, 116>> <> :binary.copy(<<0>>, 16_777_216)
             )

    assert {:ok, %{native_partial_branch_disposals: 1} = capabilities} =
             Store.Memory.capabilities(start_supervised!({Memory, []}, id: :other))

    assert capabilities.native_branches == 1
  end

  test "fresh normal readers retain pending and completed disposal and old v44 omits the new nil field" do
    store = start_supervised!(Memory)
    {_, collected, _, _} = Disposal.prepare(Memory, store, :held)
    assert {:ok, <<"smolbox-record-v44\0", payload::binary>> = old} = Codec.encode(collected)

    refute Map.has_key?(
             :erlang.binary_to_term(payload).branch.native_authority,
             :partial_disposal
           )

    assert {:ok, ^collected} = Codec.decode(old)

    {_, completed, pending, _, _} =
      Disposal.complete(
        Memory,
        start_supervised!({Memory, []}, id: :fresh_store),
        :held,
        "resolved_absent"
      )

    for record <- [pending, completed] do
      {:ok, bytes} = Codec.encode(record)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-partial-disposal-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{partial_disposal: %{request: %{"quiesced" => true}}, partial_collection: %{proof: proof}}}}} when not is_nil(proof) -> IO.puts("fresh-disposal"); _ -> System.halt(1) end/

      assert {"fresh-disposal\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end

  test "stale source acceptance leaves both records untouched and no bare absence closes backing" do
    store = start_supervised!(Memory)
    {parent, child, _, usage} = Disposal.prepare(Memory, store, :held)

    assert {:ok, current} =
             Memory.machine(store, :claim, [ManagedMachine.key(parent), "owner", 1105, 10_000])

    assert {:error, _} = Disposal.accept(Memory, store, parent, child, child.version, 1106)
    assert Disposal.fetch(Memory, store, parent) == current
    assert Disposal.fetch(Memory, store, child) == child
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:error, _} =
             Memory.machine(store, :branch_resolve, [
               ManagedMachine.key(current),
               Contract.guard(current),
               child.id,
               :absent,
               :absent,
               1106
             ])
  end
end
