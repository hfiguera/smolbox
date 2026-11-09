defmodule SmolBox.NativePartialBranchBackingTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{NativeBranchBacking, PartialBranchDisposal}
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativeBranchBackingContract,
    NativePartialBranchBackingContract
  }

  alias NativePartialBranchBackingContract, as: Contract

  for material <- [:held, :pre_release, :initial_release, :explicit_release],
      provenance <- ["deleted", "resolved_absent"] do
    test "#{material} provenance=#{provenance} closes only the original backing after durable acceptance" do
      Contract.completed(
        Memory,
        start_supervised!(Memory),
        unquote(material),
        unquote(provenance)
      )
    end
  end

  test "an accepted request is stable across claims and repeated admission and still retains all backing" do
    store = start_supervised!(Memory)
    {parent, child, usage} = Contract.prepare(Memory, store, :held)

    assert {:ok, accepted} =
             NativeBranchBackingContract.accept(Memory, store, parent, child, 1312)

    parent = NativeBranchBackingContract.fetch(Memory, store, parent)
    saved = accepted.branch.native_authority.backing

    assert {:ok, claimed} =
             Memory.machine(store, :claim, [ManagedMachine.key(accepted), "owner", 1313, 10_000])

    assert {:ok, ^claimed} =
             NativeBranchBackingContract.accept(Memory, store, parent, claimed, 1314)

    assert claimed.branch.native_authority.backing == saved
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, _} =
             NativeBranchBackingContract.complete_proof(
               Memory,
               store,
               parent,
               claimed,
               Contract.proof(saved.request),
               1315
             )
  end

  test "new state rejects stripped requests in every old envelope and preserves immutable acknowledgement" do
    store = start_supervised!(Memory)
    {parent, child, _} = Contract.prepare(Memory, store, :held)

    assert {:ok, accepted} =
             NativeBranchBackingContract.accept(Memory, store, parent, child, 1312)

    stripped = put_in(accepted.branch.native_authority.backing, nil)

    for version <- 1..47 do
      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v#{version}" <> <<0>> <> :erlang.term_to_binary(stripped)
               )
    end

    assert {:error, _} =
             ManagedMachine.update(
               accepted,
               %{
                 branch: %{
                   accepted.branch
                   | state: :retired,
                     native_authority: %{accepted.branch.native_authority | backing: nil}
                 }
               },
               1313
             )

    parent = NativeBranchBackingContract.fetch(Memory, store, parent)
    proof = Contract.proof(accepted.branch.native_authority.backing.request)

    assert {:ok, closed} =
             NativeBranchBackingContract.complete_proof(
               Memory,
               store,
               parent,
               accepted,
               proof,
               1313
             )

    assert {:error, _} =
             ManagedMachine.update(
               closed,
               %{
                 branch: %{
                   closed.branch
                   | state: :backing_pending,
                     native_authority: %{
                       closed.branch.native_authority
                       | backing: %{closed.branch.native_authority.backing | proof: nil}
                     }
                 }
               },
               1314
             )
  end

  test "the exact disposal child root and source head are required for every accounting acknowledgement" do
    store = start_supervised!(Memory)
    {parent, child, usage} = Contract.prepare(Memory, store, :initial_release)
    assert {:ok, pending} = NativeBranchBackingContract.accept(Memory, store, parent, child, 1312)
    parent = NativeBranchBackingContract.fetch(Memory, store, parent)
    saved = pending.branch.native_authority.backing

    assert saved.request["child"] ==
             (get_in(saved.request, ~w(disposal release receipt)) ||
                get_in(saved.request, ~w(disposal publication change child)))

    assert saved.request["disposal"] ==
             PartialBranchDisposal.to_wire(child.branch.native_authority.partial_disposal.proof)

    for wrong <- [
          %{Contract.proof(saved.request) | operation_id: "different-release"},
          %{Contract.proof(saved.request) | request_sha256: String.duplicate("0", 64)}
        ] do
      assert {:error, _} =
               NativeBranchBackingContract.complete_proof(
                 Memory,
                 store,
                 parent,
                 pending,
                 wrong,
                 1313
               )

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
    end

    refute NativeBranchBacking.valid?(
             %{saved | version: pending.branch.native_authority.retirement.version},
             pending.branch.native_authority
           )
  end

  test "fresh BEAM readers retain pending and closed v47 authority without native assets" do
    store = start_supervised!(Memory)
    {parent, child, _} = Contract.prepare(Memory, store, :held)
    assert {:ok, pending} = NativeBranchBackingContract.accept(Memory, store, parent, child, 1312)
    parent = NativeBranchBackingContract.fetch(Memory, store, parent)

    assert {:ok, closed} =
             NativeBranchBackingContract.complete_proof(
               Memory,
               store,
               parent,
               pending,
               Contract.proof(pending.branch.native_authority.backing.request),
               1313
             )

    for record <- [pending, closed] do
      bytes = Contract.roundtrip(record)

      path =
        Path.join(
          System.tmp_dir!(),
          "smolbox-partial-backing-#{System.unique_integer([:positive])}"
        )

      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, record} -> if SmolBox.ManagedMachine.validate(record) == :ok, do: IO.puts("fresh-partial-backing"), else: System.halt(1); _ -> System.halt(1) end/

      assert {"fresh-partial-backing\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end
  end

  test "v47 rejects disposal or retirement-only payloads and overlong envelopes" do
    {_, child, _} = Contract.prepare(Memory, start_supervised!(Memory), :held)
    assert {:ok, <<"smolbox-record-v46", 0, body::binary>> = before} = Codec.encode(child)
    assert {:error, _} = Codec.decode("smolbox-record-v47" <> <<0>> <> body)

    assert {:error, _} =
             Codec.decode("smolbox-record-v47" <> <<0>> <> :binary.copy("x", 16_777_216))

    assert {:ok, ^child} = Codec.decode(before)
  end
end
