defmodule SmolBox.NativeUnbootedBranchDisposalTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{NativeUnbootedBranchDisposal, NativeUnbootedBranchDisposalResult}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativeUnbootedBranchDisposalContract,
    NativeUnbootedBranchDisposalOps
  }

  alias NativeUnbootedBranchDisposalContract, as: Contract

  for hold <- [true, false], provenance <- ["deleted", "resolved_absent"] do
    test "held=#{hold} provenance=#{provenance} commits real source history and keeps backing/dependency charged" do
      Contract.complete(Memory, start_supervised!(Memory), unquote(hold), unquote(provenance))
    end
  end

  test "an accepted intent remains immutable across child claims and rejects stale completion versions" do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, false)
    assert {:ok, child} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(child, completion)

    assert {:ok, fresh} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1104, 10_000])

    assert fresh.branch.native_authority.disposal == child.branch.native_authority.disposal
    assert {:error, _} = Contract.resolve(Memory, store, parent, fresh, result, 1105)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, _} =
             Contract.resolve(
               Memory,
               store,
               parent,
               fresh,
               %{result | version: fresh.version},
               1105
             )
  end

  test "missing accepted intent or changed observations and proof cannot free ordinary capacity" do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, true)
    request = NativeUnbootedBranchDisposal.new(child.branch.native_authority, child.version)
    synthetic = put_in(child.branch.native_authority.disposal, request)
    result = Contract.result(synthetic, completion)
    refute NativeUnbootedBranchDisposalResult.bound?(result, parent, child)
    assert {:error, _} = NativeUnbootedBranchDisposalOps.resolve(parent, child, result, 1103)
    assert {:ok, accepted} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(accepted, completion)

    for wrong <- [
          %{result | version: accepted.version + 1},
          put_in(result.source.backend_identity.pid_identity, [999, 999]),
          put_in(
            result.source.backend_identity.receipt["material"]["record_sha256"],
            String.duplicate("e", 64)
          ),
          %{result | source: %{result.source | network: :enabled}},
          %{
            result
            | proof: %{result.proof | request: Map.put(result.proof.request, "quiesced", false)}
          }
        ] do
      assert {:error, _} = Contract.resolve(Memory, store, parent, accepted, wrong, 1104)
      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert Contract.fetch(Memory, store, parent) == parent
      assert Contract.fetch(Memory, store, accepted) == accepted
    end
  end

  test "new disposal records require v37 while legacy envelopes retain exact bytes" do
    store = start_supervised!(Memory)
    {parent, child, _, _} = Contract.prepare(Memory, store, true)
    assert {:ok, before} = Codec.encode(child)
    refute String.starts_with?(before, "smolbox-record-v37")
    assert {:ok, legacy} = Codec.decode(before)
    assert legacy == child
    assert {:ok, ^before} = Codec.encode(legacy)
    assert {:ok, accepted} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    assert {:ok, <<"smolbox-record-v37", 0, body::binary>>} = Codec.encode(accepted)

    for version <- 15..36 do
      assert {:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> body)
    end

    assert {:error, _} = Codec.decode("smolbox-record-v37" <> <<0, 131, 80, 0>>)
  end

  test "disposal history cannot be erased re-opened or changed into ready completion" do
    {parent, child, _, _} = Contract.complete(Memory, start_supervised!(Memory), true)
    saved = child.branch.native_authority.disposal

    for authority <- [
          %{child.branch.native_authority | disposal: nil},
          %{
            child.branch.native_authority
            | disposal: %{saved | proof: nil, completion_version: nil}
          },
          %{child.branch.native_authority | disposal: %{saved | version: child.version}}
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{branch: %{child.branch | native_authority: authority}},
                 1200
               )
    end

    assert {:error, _} = ManagedMachine.update(parent, %{native_branch_history: %{}}, 1200)
    assert {:error, _} = ManagedMachine.update(child, %{state: :running}, 1200)
  end

  test "request acceptance is idempotent and stopped source publication remains positive evidence" do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, true)
    original = child.version
    assert {:error, _} = Contract.accept(Memory, store, parent, child, original + 1, 1103)
    assert {:ok, accepted} = Contract.accept(Memory, store, parent, child, original, 1103)
    parent = Contract.fetch(Memory, store, parent)
    assert {:ok, ^accepted} = Contract.accept(Memory, store, parent, accepted, original, 1104)
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    result = Contract.result(accepted, completion)

    stopped = %{
      result.source
      | state: :stopped,
        backend_identity: %{result.source.backend_identity | pid_identity: nil}
    }

    assert {:ok, _} =
             Contract.resolve(Memory, store, parent, accepted, %{result | source: stopped}, 1105)

    assert Contract.fetch(Memory, store, parent).state == :stopped
  end

  test "v37 state markers reject stripped downgrades and fresh BEAM readers need no native assets" do
    store = start_supervised!(Memory)
    {parent, child, completion, _} = Contract.prepare(Memory, store, false)
    assert {:ok, accepted} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(accepted, completion)
    assert {:ok, disposed} = Contract.resolve(Memory, store, parent, accepted, result, 1104)

    for record <- [accepted, disposed] do
      assert {:ok, bytes} = Codec.encode(record)
      stripped = update_in(record.branch.native_authority, &Map.delete(&1, :disposal))

      for version <- 15..36 do
        assert {:error, _} =
                 Codec.decode(
                   "smolbox-record-v#{version}" <> <<0>> <> :erlang.term_to_binary(stripped)
                 )
      end

      assert {:error, _} = Codec.decode(bytes <> "tail")

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-unbooted-disposal-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, record} -> if SmolBox.ManagedMachine.validate(record) == :ok, do: IO.puts("fresh-unbooted-disposal"), else: System.halt(1); _ -> System.halt(1) end/

      assert {"fresh-unbooted-disposal\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end
end
