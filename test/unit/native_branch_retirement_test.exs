defmodule SmolBox.NativeBranchRetirementTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.NativeBranchRetirement
  alias SmolBox.ManagedMachine
  alias SmolBox.Store.{Codec, Memory, NativeBranchRetirementContract, NativeBranchRetirementOps}

  for mode <- [:held, :ready, :released] do
    test "#{mode} retirement proves current absence and atomically retires dependency without backing release" do
      NativeBranchRetirementContract.complete(Memory, start_supervised!(Memory), unquote(mode))
    end
  end

  test "proof from an older child version cannot complete retirement" do
    store = start_supervised!(Memory)
    {parent, child, proof, usage} = NativeBranchRetirementContract.prepare(Memory, store, :held)

    assert {:ok, fresh} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1304, 10_000])

    assert {:error, _} =
             NativeBranchRetirementContract.advance(Memory, store, parent, child, proof, 1305)

    assert {:ok, ^fresh} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativeBranchRetirementContract.advance(
               Memory,
               store,
               parent,
               fresh,
               NativeBranchRetirementContract.proof(fresh),
               1305
             )
  end

  test "v32 retirement proof is immutable and earlier v30/v31 records retain exact envelopes" do
    {_, child, proof, _} =
      NativeBranchRetirementContract.complete(Memory, start_supervised!(Memory), :released)

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{
                 branch: %{
                   child.branch
                   | native_authority: %{child.branch.native_authority | retirement: nil}
                 }
               },
               1400
             )

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{branch: %{child.branch | state: :released, retired_at_ms: nil}},
               1400
             )

    changed = %{child.branch.native_authority.retirement | version: child.version}

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{
                 branch: %{
                   child.branch
                   | native_authority: %{child.branch.native_authority | retirement: changed}
                 }
               },
               1400
             )

    assert {:ok, request} = NativeBranchRetirement.request(child)
    assert request == proof.request

    for mode <- [:held, :released] do
      stop_supervised!(Memory)
      store = start_supervised!(Memory)
      {_source, prior, _, _} = NativeBranchRetirementContract.prepare(Memory, store, mode)
      expected = if mode == :held, do: "smolbox-record-v30", else: "smolbox-record-v31"
      assert {:ok, bytes} = Codec.encode(prior)

      assert bytes ==
               expected <>
                 <<0>> <>
                 :erlang.term_to_binary(
                   update_in(
                     prior.branch.native_authority,
                     &(&1
                       |> Map.delete(:retirement)
                       |> Map.delete(:backing)
                       |> Map.delete(:deletion)
                       |> Map.delete(:delete_continuation)
                       |> Map.delete(:delete_cleanup)
                       |> Map.delete(:delete_collection)
                       |> Map.delete(:prepared_retirement)
                       |> Map.delete(:disposal))
                   )
                   |> strip_release(mode)
                 )

      assert {:ok, ^prior} = Codec.decode(bytes)
    end
  end

  defp strip_release(record, :held),
    do: update_in(record.branch.native_authority, &Map.delete(&1, :release))

  defp strip_release(record, _), do: record

  test "older experimental retirement states remain readable but need fresh proof for native ratification" do
    {source, child, _, _} =
      NativeBranchRetirementContract.complete(Memory, start_supervised!(Memory), :held)

    legacy = %{
      child
      | branch: %{
          child.branch
          | native_authority: %{child.branch.native_authority | retirement: nil}
        }
    }

    assert :ok = ManagedMachine.validate(legacy)
    assert {:ok, <<"smolbox-record-v30\0", _::binary>> = bytes} = Codec.encode(legacy)
    assert {:ok, ^legacy} = Codec.decode(bytes)
    assert {:error, _} = NativeBranchRetirementOps.retire(source, legacy, :absent, 1400)
    proof = NativeBranchRetirementContract.proof(legacy)
    assert {:ok, _, ratified} = NativeBranchRetirementOps.retire(source, legacy, proof, 1400)
    assert ratified.branch.retired_at_ms == legacy.branch.retired_at_ms
    NativeBranchRetirementContract.roundtrip(ratified)
  end

  test "fresh BEAM reads retirement authority without native tools" do
    {_, child, _, _} =
      NativeBranchRetirementContract.complete(Memory, start_supervised!(Memory), :held)

    bytes = NativeBranchRetirementContract.roundtrip(child)

    path =
      Path.join(System.tmp_dir!(), "smolbox-retirement-#{System.unique_integer([:positive])}")

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code =
      ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{state: :retired, native_authority: %{retirement: %{proof: %{schema: 1}}}}}} -> IO.puts("fresh-retirement"); _ -> System.halt(1) end/

    assert {"fresh-retirement\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
