defmodule SmolBox.NativeBranchReleaseTest do
  use ExUnit.Case, async: true
  alias SmolBox.{BranchSpec, Command, Execution, ExecutionSpec, ManagedMachine}

  alias SmolBox.Backend.Assignment

  alias SmolBox.Store.{
    Codec,
    MachineOps,
    Memory,
    NativeBranchContract,
    NativeBranchReleaseContract
  }

  for uncertain <- [false, true] do
    test "held release uncertain=#{uncertain} binds both records and retains all backing" do
      NativeBranchReleaseContract.completed(Memory, start_supervised!(Memory), unquote(uncertain))
    end
  end

  test "release freezes the advanced source head after sibling creation and excludes concurrent source work" do
    store = start_supervised!(Memory)
    {source, first, _, _} = NativeBranchContract.complete(Memory, store, true)
    key = ManagedMachine.key(source)
    spec = %{first.branch.spec | id: "sibling"}
    fingerprint = BranchSpec.fingerprint(spec, key, String.duplicate("k", 32))
    capacity = %{slots: 16, cpus: 32, memory_mb: 65_536, disk_gb: 1024}

    assert {:ok, sibling} =
             Memory.machine(store, :branch_accept, [
               key,
               spec,
               fingerprint,
               "owned-sibling",
               capacity,
               1150
             ])

    assert {:ok, source} = Memory.machine(store, :fetch, [key])
    result = NativeBranchContract.result(source, sibling)
    result = put_in(result.child.backend_identity.pid_identity, [345, 678])

    assert {:ok, _} =
             NativeBranchContract.advance(
               Memory,
               store,
               source,
               sibling,
               :accepted,
               :dispatching,
               1151
             )

    assert {:ok, source} = Memory.machine(store, :fetch, [key])

    assert {:ok, sibling} =
             NativeBranchContract.advance(
               Memory,
               store,
               source,
               sibling,
               :dispatching,
               {:native_complete, result},
               1152
             )

    assert {:ok, source} = Memory.machine(store, :fetch, [key])
    assert source.observed_machine.backend_identity.receipt["material"]["revision"] == 2
    assert {:ok, usage} = Memory.usage(store, source.worker_id)

    assert {:ok, pending} =
             Memory.machine(store, :branch_release, [
               ManagedMachine.key(first),
               first.version,
               1200
             ])

    assert pending.branch.native_authority.release.source ==
             source.observed_machine.backend_identity.receipt

    refute pending.branch.native_authority.release.source ==
             pending.branch.native_authority.completion.publication["receipt"]

    assert {:error, _} =
             Memory.machine(store, :branch_release, [
               ManagedMachine.key(sibling),
               sibling.version,
               1200
             ])

    assert {:ok, ^sibling} = Memory.machine(store, :fetch, [ManagedMachine.key(sibling)])

    assert {:ok, pending} =
             Memory.machine(store, :claim, [ManagedMachine.key(pending), "owner", 1200, 10_000])

    assert {:ok, sent} =
             NativeBranchReleaseContract.advance(Memory, store, pending, :dispatching, 1201)

    assert {:ok, source} = Memory.machine(store, :fetch, [key])
    result = NativeBranchReleaseContract.result(source, sent)

    assert {:ok, _} =
             NativeBranchReleaseContract.advance(
               Memory,
               store,
               sent,
               {:native_complete, result},
               1202
             )

    assert {:ok, ^sibling} = Memory.machine(store, :fetch, [ManagedMachine.key(sibling)])
    assert {:ok, ^usage} = Memory.usage(store, source.worker_id)
    assert {:ok, %{active_branch: nil}} = Memory.machine(store, :fetch, [key])
  end

  test "fresh BEAM decodes v31 release authority without native tooling" do
    {_, child, _, _} = NativeBranchReleaseContract.completed(Memory, start_supervised!(Memory))
    assert {:ok, bytes} = Codec.encode(child)
    path = Path.join(System.tmp_dir!(), "smolbox-release-#{System.unique_integer([:positive])}")
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code =
      ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do / <>
        ~S/{:ok, %{branch: %{state: :released, native_authority: %{release: %{transition: %{schema: 1}}}}}} -> IO.puts("fresh-release"); / <>
        ~S/_ -> System.halt(1) end/

    assert {"fresh-release\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "released command authority uses v31 and cannot substitute the original source or release intent" do
    {_, child, _, _} = NativeBranchReleaseContract.completed(Memory, start_supervised!(Memory))
    assert {:ok, command} = Command.new(["true"])

    assert {:ok, spec} =
             ExecutionSpec.new(
               scope: child.scope,
               id: "released-command",
               profile: child.spec.profile,
               artifact: child.spec.artifact,
               command: command
             )

    assert {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    assert {:ok, initial} = Execution.new(spec, fingerprint, 1300)
    assert {:ok, _, attached} = MachineOps.attach(child, initial, 1300)
    assert {:ok, <<"smolbox-record-v31\0", body::binary>> = bytes} = Codec.encode(attached)
    assert {:ok, ^attached} = Codec.decode(bytes)
    assert {:error, _} = Codec.decode("smolbox-record-v30\0" <> body)

    changed =
      put_in(attached.backend_assignment.creation["branch"]["source"]["name"], "foreign-source")

    assert Assignment.valid?(changed.backend_assignment)
    assert {:error, _} = Execution.validate(changed)
    assert {:error, _} = Codec.encode(changed)
    dropped = %{child.branch.native_authority | release: nil}

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{branch: %{child.branch | native_authority: dropped}},
               1300
             )

    changed_release = %{
      child.branch.native_authority.release
      | version: child.branch.release_version + 1
    }

    assert {:error, _} =
             ManagedMachine.update(
               child,
               %{
                 branch: %{
                   child.branch
                   | native_authority: %{child.branch.native_authority | release: changed_release},
                     release_version: changed_release.version
                 }
               },
               1300
             )
  end
end
