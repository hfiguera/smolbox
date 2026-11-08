defmodule SmolBox.NativeCollectedBranchPublicationTest do
  use ExUnit.Case, async: true
  alias SmolBox.ManagedMachine

  alias SmolBox.Store.{
    Codec,
    Memory,
    NativeBranchContract,
    NativeUnbootedBranchDisposalContract
  }

  alias SmolBox.Store.NativeCollectedBranchPublicationContract, as: Contract

  for hold <- [true, false] do
    test "held=#{hold} publication keeps unknown child and every charge and permits exact ready resolution" do
      store = start_supervised!(Memory)
      {parent, child, _, completion, usage} = Contract.complete(Memory, store, unquote(hold))

      assert {:ok, ready} =
               NativeUnbootedBranchDisposalContract.resolve(
                 Memory,
                 store,
                 parent,
                 child,
                 completion,
                 1110
               )

      source = Contract.fetch(Memory, store, parent)
      assert source.native_branch_history == parent.native_branch_history
      assert ready.branch.state == if(unquote(hold), do: :held, else: :ready)

      assert ready.branch.native_authority.collected_publication ==
               child.branch.native_authority.collected_publication

      assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
      assert {:ok, bytes} = Codec.encode(ready)
      assert {:ok, ^ready} = Codec.decode(bytes)
    end

    test "held=#{hold} actual unbooted disposal retains the exact publication and releases ordinary capacity only" do
      store = start_supervised!(Memory)
      {parent, child, _, completion, _} = Contract.complete(Memory, store, unquote(hold))

      assert {:ok, pending} =
               NativeUnbootedBranchDisposalContract.accept(
                 Memory,
                 store,
                 parent,
                 child,
                 child.version,
                 1110
               )

      parent = Contract.fetch(Memory, store, parent)
      result = NativeUnbootedBranchDisposalContract.result(pending, completion)

      assert {:ok, disposed} =
               NativeUnbootedBranchDisposalContract.resolve(
                 Memory,
                 store,
                 parent,
                 pending,
                 result,
                 1111
               )

      source = Contract.fetch(Memory, store, parent)
      assert source.native_branch_history == parent.native_branch_history
      assert disposed.branch.state == :disposed and disposed.reservation == nil

      assert disposed.branch.native_authority.collected_publication ==
               child.branch.native_authority.collected_publication

      assert {:ok, bytes} = Codec.encode(disposed)
      assert {:ok, ^disposed} = Codec.decode(bytes)
    end
  end

  test "crossed results and readiness before publication acknowledgment leave the atomic pair unchanged" do
    Contract.reject_crossed(Memory, start_supervised!(Memory))
  end

  test "claim changes require a fresh result version while preserving the accepted full creation" do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, false)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(pending, completion)

    assert {:ok, claimed} =
             Memory.machine(store, :claim, [ManagedMachine.key(child), "owner", 1104, 10_000])

    assert {:error, _} = Contract.finish(Memory, store, parent, claimed, result, 1105)
    assert Contract.fetch(Memory, store, parent) == parent
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)

    assert {:ok, _} =
             Contract.finish(
               Memory,
               store,
               parent,
               claimed,
               %{result | version: claimed.version},
               1106
             )
  end

  test "partial collection and disposal consume the same saved publication without a second history link" do
    Contract.complete_partial(Memory, start_supervised!(Memory))
  end

  test "a stopped source observation publishes material without changing unknown source or child state" do
    store = start_supervised!(Memory)
    {parent, child, completion, usage} = Contract.prepare(Memory, store, true)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)
    result = Contract.result(pending, completion)

    stopped = %{
      result.source
      | state: :stopped,
        backend_identity: %{result.source.backend_identity | pid_identity: nil}
    }

    assert {:ok, published} =
             Contract.finish(Memory, store, parent, pending, %{result | source: stopped}, 1104)

    source = Contract.fetch(Memory, store, parent)
    assert source.state == :unknown and source.observed_machine == stopped
    assert published.state == :unknown and published.created_machine == nil
    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "publication can follow an already collected partial child with its matching material digest" do
    Contract.publish_after_collection(Memory, start_supervised!(Memory))
  end

  test "a pending publication prevents crossed platform collection acceptance" do
    store = start_supervised!(Memory)
    {parent, child, _, usage} = Contract.prepare(Memory, store, true)
    assert {:ok, pending} = Contract.accept(Memory, store, parent, child, child.version, 1103)
    parent = Contract.fetch(Memory, store, parent)

    assert {:error, _} =
             NativeBranchContract.advance(
               Memory,
               store,
               parent,
               pending,
               :unknown,
               {:accept_partial_collection, pending.version, "linux"},
               1104
             )

    assert Contract.fetch(Memory, store, parent) == parent and
             Contract.fetch(Memory, store, pending) == pending

    assert {:ok, ^usage} = Memory.usage(store, parent.worker_id)
  end

  test "saved request and publication cannot be removed changed or used as readiness or deletion" do
    {_, child, pending, _, _} = Contract.complete(Memory, start_supervised!(Memory), false)
    saved = child.branch.native_authority.collected_publication

    for replacement <- [
          nil,
          %{saved | proof: nil, completion_version: nil},
          %{saved | platform: "linux"},
          %{
            saved
            | request:
                put_in(
                  saved.request,
                  ["creation", "initial_release", "operation_id"],
                  "different"
                )
          }
        ] do
      assert {:error, _} =
               ManagedMachine.update(
                 child,
                 %{
                   branch: %{
                     child.branch
                     | native_authority: %{
                         child.branch.native_authority
                         | collected_publication: replacement
                       }
                   }
                 },
                 1110
               )
    end

    for record <- [pending, child],
        changes <- [
          %{branch: %{record.branch | state: :ready}},
          %{
            state: :deleted,
            reservation: nil,
            operation: nil,
            phase: nil,
            operation_deadline_ms: nil
          }
        ] do
      assert {:error, _} = ManagedMachine.update(record, changes, 1110)
    end
  end

  test "v50 is selective rejects older tags and malformed payloads and loads in a cold BEAM" do
    {_, child, pending, _, _} = Contract.complete(Memory, start_supervised!(Memory), false)

    for record <- [pending, child] do
      assert {:ok, <<"smolbox-record-v50", 0, payload::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)

      for version <- 1..49,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}" <> <<0>> <> payload))

      assert {:error, _} = Codec.decode(bytes <> <<0>>)

      assert {:error, _} =
               Codec.decode(
                 "smolbox-record-v50" <> <<0>> <> :erlang.term_to_binary(record, [:compressed])
               )

      stripped = put_in(record.branch.native_authority.collected_publication, nil)

      assert {:error, _} =
               Codec.decode("smolbox-record-v50" <> <<0>> <> :erlang.term_to_binary(stripped))

      path = Path.join(System.tmp_dir!(), "sb-publication-#{System.unique_integer([:positive])}")
      File.write!(path, bytes, [:exclusive])
      File.chmod!(path, 0o600)
      on_exit(fn -> File.rm(path) end)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

      code =
        ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{branch: %{native_authority: %{collected_publication: %{request: %{"quiesced" => true}}}}}} -> IO.puts("fresh-publication"); _ -> System.halt(1) end/

      assert {"fresh-publication\n", 0} =
               System.cmd(
                 System.find_executable("elixir"),
                 Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
                 stderr_to_stdout: true
               )
    end

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v50" <> <<0, 131, 116>> <> :binary.copy(<<0>>, 16_777_216)
             )

    assert {:ok, %{native_collected_branch_publications: 1} = caps} =
             Memory.capabilities(start_supervised!(Memory, id: :other))

    assert caps.native_branches == 1
  end

  test "ordinary v30 creation payload still omits exactly the new nil default" do
    {_, child, _} = NativeBranchContract.prepare(Memory, start_supervised!(Memory), true)
    assert {:ok, <<"smolbox-record-v30", 0, payload::binary>> = bytes} = Codec.encode(child)
    legacy = :erlang.binary_to_term(payload)
    refute Map.has_key?(legacy.branch.native_authority, :collected_publication)
    assert {:ok, ^child} = Codec.decode(bytes)

    injected =
      update_in(legacy.branch.native_authority, &Map.put(&1, :collected_publication, nil))

    assert {:error, _} =
             Codec.decode("smolbox-record-v30" <> <<0>> <> :erlang.term_to_binary(injected))
  end
end
