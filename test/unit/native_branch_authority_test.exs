defmodule SmolBox.NativeBranchAuthorityTest do
  use ExUnit.Case, async: true

  alias SmolBox.{
    BranchPolicy,
    BranchSpec,
    Command,
    Execution,
    ExecutionSpec,
    ManagedMachine,
    ManagedMachineSpec,
    NetworkPolicy,
    Profile
  }

  alias SmolBox.Backend.Assignment

  alias SmolBox.Embedded.{
    BranchCreation,
    BranchPublication,
    CreationFeatures,
    Identity,
    NativeBranchAuthority,
    NativeGrowth,
    Request
  }

  alias SmolBox.Store.{
    BranchOps,
    Codec,
    Contract,
    ExpansionOps,
    MachineOps,
    Memory,
    NativeCaptureContract
  }

  @capacity %{slots: 8, cpus: 16, memory_mb: 8192, disk_gb: 128}

  defp source(receipt \\ nil) do
    original = NativeCaptureContract.fixture()
    original = if receipt, do: bind_root(original, receipt), else: original

    observed = %{
      original.observed_machine
      | state: :running,
        backend_identity: %{original.observed_machine.backend_identity | pid_identity: [123, 456]}
    }

    {:ok, running} =
      ManagedMachine.update(original, %{state: :running, observed_machine: observed}, 1001)

    running
  end

  defp bind_root(original, receipt) do
    creation =
      Map.merge(
        original.backend_assignment.creation,
        Map.take(receipt, ~w(name owner_token incarnation))
      )

    assignment = %{
      original.backend_assignment
      | creation: creation,
        binding: %{
          original.backend_assignment.binding
          | target_id: receipt["target_id"],
            generation: receipt["domain_generation"]
        }
    }

    created = %{
      original.created_machine
      | name: receipt["name"],
        backend_identity: %Identity{receipt: receipt}
    }

    %{
      original
      | machine_name: receipt["name"],
        worker_id: receipt["target_id"],
        backend_assignment: assignment,
        created_machine: created,
        observed_machine: created
    }
  end

  defp spec(hold) do
    {:ok, policy} =
      BranchPolicy.new(
        id: "branches",
        resources: %{slots: 1, cpus: 1, memory_mb: 512, disk_gb: 5}
      )

    {:ok, spec} = BranchSpec.new(id: "leaf", policy: policy, idle: true, hold: hold)
    spec
  end

  defp accept(parent, hold) do
    spec = spec(hold)

    fingerprint =
      BranchSpec.fingerprint(spec, ManagedMachine.key(parent), String.duplicate("k", 32))

    BranchOps.accept(parent, spec, fingerprint, "owned-leaf", @capacity, parent.reservation, 1100)
  end

  test "static egress requires a held branch and preserves the source allowlist in the assignment" do
    original = source()
    {:ok, network} = NetworkPolicy.new(hosts: ["example.com"], cidrs: ["192.0.2.1/32"])
    parent = networked_source(original, network, false)
    assert :ok = ManagedMachine.validate(parent)
    assert {:error, _} = accept(parent, false)
    assert {:ok, _, child} = accept(parent, true)
    assert child.spec.branch_static_egress
    assert child.spec.profile.network == network
    assert {:ok, <<"smolbox-record-v52\0", _::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)
    assert BranchCreation.matches?(child.backend_assignment.creation, child.spec)
    assert {:ok, different} = NetworkPolicy.new(hosts: ["example.org"])
    assert {:error, _} = Codec.encode(put_in(child.spec.profile.network, different))
  end

  defp networked_source(original, network, credentialed) do
    profile = %{original.spec.profile | network: network}

    spec = %{
      original.spec
      | profile: profile,
        checkpointable: credentialed,
        branch_static_egress: not credentialed
    }

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))

    creation =
      CreationFeatures.attach(
        original.backend_assignment.creation,
        CreationFeatures.from_spec(spec)
      )

    %{
      original
      | spec: spec,
        fingerprint: fingerprint,
        created_machine: %{original.created_machine | network: network},
        observed_machine: %{original.observed_machine | network: network},
        backend_assignment: %{original.backend_assignment | creation: creation}
    }
  end

  test "credential sources require held children and roundtrip source and child as v53" do
    {:ok, network} = NetworkPolicy.new(hosts: ["api.example.test"])
    parent = networked_source(source(), network, true)
    assert :ok = ManagedMachine.validate(parent)
    assert parent.backend_assignment.creation["features"]["branch_https"]
    assert {:ok, <<"smolbox-record-v53\0", _::binary>> = bytes} = Codec.encode(parent)
    assert {:ok, ^parent} = Codec.decode(bytes)
    assert {:error, _} = accept(parent, false)
    assert {:ok, _, child} = accept(parent, true)
    assert SmolBox.BranchHTTPSCredentials.child?(child)
    assert {:ok, <<"smolbox-record-v53\0", _::binary>> = bytes} = Codec.encode(child)
    assert {:ok, ^child} = Codec.decode(bytes)
    assert {:error, _} = Codec.encode(put_in(child.spec.profile.network, :offline))
  end

  test "credential denial cancels only an undispatched release and leaves the held child retryable" do
    alias SmolBox.Store.{NativeBranchContract, NativeBranchReleaseOps}
    {parent, held, _, _} = NativeBranchContract.complete(Memory, start_supervised!(Memory), true)

    assert {:ok, parent, pending} =
             NativeBranchReleaseOps.accept(parent, held, held.version, 1103)

    assert {:ok, saved_parent, saved_child} =
             NativeBranchReleaseOps.advance(
               parent,
               pending,
               :release_pending,
               :credential_unavailable,
               1104
             )

    assert saved_child.branch.state == :held
    assert saved_child.branch.native_authority.release == nil
    assert saved_child.last_error.category == :authentication
    assert saved_parent.active_branch == nil

    assert {:ok, _, _} =
             NativeBranchReleaseOps.accept(saved_parent, saved_child, saved_child.version, 1105)

    assert {:ok, parent, dispatched} =
             NativeBranchReleaseOps.advance(parent, pending, :release_pending, :dispatching, 1104)

    assert {:error, _} =
             NativeBranchReleaseOps.advance(
               parent,
               dispatched,
               :release_dispatching,
               :credential_unavailable,
               1105
             )
  end

  defmodule DeniedCredentialResolver do
    @behaviour SmolBox.BranchHTTPSCredentials
    @impl true
    def resolve(_, _), do: :error
  end

  test "retained commands preserve the frozen static and credential branch modes" do
    for credentialed <- [false, true] do
      alias SmolBox.Embedded.Config
      alias SmolBox.Test.EmbeddedPackage, as: Package
      {:ok, network} = NetworkPolicy.new(hosts: ["api.example.test"])
      original = source()
      artifact = Map.put(original.spec.artifact, "architecture", "x86_64")
      original = %{original | spec: %{original.spec | artifact: artifact}}

      original =
        put_in(original.backend_assignment.creation["artifact"]["guest_platform"], "linux/amd64")

      parent = networked_source(original, network, credentialed)
      assert {:ok, _, child} = accept(parent, true)

      sdk = "native/policy-linux.json" |> File.read!() |> Jason.decode!() |> get_in(["sdk"])

      native =
        Package.create(
          protocol_major: 2,
          platform: :linux,
          smolvm_revision: sdk["source_revision"],
          sdk_identity: sdk
        )

      on_exit(fn -> Package.remove!(native) end)

      native = %{
        native
        | id: parent.worker_id,
          domain_generation: parent.backend_assignment.binding.generation,
          profiles: [parent.spec.profile],
          artifacts: [
            Map.merge(artifact, %{"path" => "/fixture.smolmachine", "max_bytes" => 1024})
          ],
          branch_policies: [child.branch.spec.policy],
          branch_https_credentials:
            if(credentialed, do: {DeniedCredentialResolver, nil}, else: nil)
      }

      assert :ok = Config.validate(native)
      assert Assignment.approved?(child.backend_assignment, native, child.spec)
      {:ok, command} = Command.new(["/bin/true"])

      {:ok, execution} =
        ExecutionSpec.new(
          scope: child.scope,
          id: "retained-command",
          artifact: child.spec.artifact,
          profile: child.spec.profile,
          command: command
        )

      assert Assignment.approved?(
               child.backend_assignment,
               native,
               execution,
               ManagedMachine.key(child)
             )

      assert get_in(child.backend_assignment.creation, ["features", "branch_https"]) ==
               if(credentialed, do: true)

      if credentialed do
        refute Assignment.approved?(
                 child.backend_assignment,
                 %{native | branch_https_credentials: nil},
                 execution,
                 ManagedMachine.key(child)
               )
      end
    end
  end

  test "checkpointable native branch sources retain the shared disk-growth exclusion" do
    original = source()

    stopped = %{
      original.observed_machine
      | state: :stopped,
        backend_identity: %{original.observed_machine.backend_identity | pid_identity: nil}
    }

    assert {:ok, original} =
             ManagedMachine.update(original, %{state: :stopped, observed_machine: stopped}, 1002)

    assert {:error, %{category: :unsupported_capability}} =
             ExpansionOps.accept(
               original,
               "grow.1",
               original.version,
               %{storage_gb: 2},
               %{disk_gb: 64},
               original.reservation,
               1010
             )

    assert original.disk_expansions == %{} and original.created_machine.storage_gb == 1
  end

  test "source publication advances append-only material history without rewriting creation authority" do
    rows =
      "../../native/smolbox-protocol/fixtures/branch-creation-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    for row <- rows do
      assert {:ok, proof} = BranchPublication.from_wire(row["completion"]["publication"])
      original = source(proof.previous)
      profile = %{original.spec.profile | host_overhead_mb: 128}
      source_spec = %{original.spec | profile: profile}
      {:ok, fingerprint} = ManagedMachineSpec.fingerprint(source_spec, String.duplicate("k", 32))

      original = %{
        original
        | spec: source_spec,
          fingerprint: fingerprint,
          reservation: Profile.resources(profile)
      }

      assert :ok = ManagedMachine.validate(original)

      identity = %Identity{
        receipt: proof.receipt,
        transition: proof,
        material_history: [proof],
        pid_identity: [123, 456]
      }

      observation = %{original.observed_machine | backend_identity: identity}
      id = proof.receipt["material"]["operation_id"]
      history = %{id => proof}

      assert {:ok, saved} =
               ManagedMachine.update(
                 original,
                 %{
                   native_branch_history: history,
                   branch_children: %{id => false},
                   observed_machine: observation
                 },
                 1100
               )

      assert saved.created_machine == original.created_machine

      assert {:ok, receipt, %{"storage_gib" => 1, "overlay_gib" => 1}, ^proof} =
               NativeGrowth.head(saved)

      assert receipt == proof.receipt
      assert {:ok, [^proof]} = NativeGrowth.transitions(saved)
      assert {:ok, <<"smolbox-record-v30\0", body::binary>> = bytes} = Codec.encode(saved)
      assert {:ok, ^saved} = Codec.decode(bytes)

      assert {:ok, locked, next_child} = accept(saved, true)
      assert locked.created_machine == original.created_machine
      assert locked.native_branch_history == history
      assert next_child.branch.native_authority.request["source"] == proof.receipt
      assert next_child.branch.source_machine.backend_identity.material_history == [proof]

      for version <- 1..29,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

      assert {:error, _} =
               ManagedMachine.update(
                 saved,
                 %{
                   native_branch_history: %{},
                   branch_children: %{},
                   observed_machine: original.observed_machine
                 },
                 1101
               )

      assert {:error, _} =
               ManagedMachine.transition(saved, [native_branch_history: history], 1101)

      assert {:error, _} = Codec.encode(%{saved | native_branch_history: %{}})
      assert {:error, _} = Codec.encode(%{saved | observed_machine: original.observed_machine})
      assert {:error, _} = Codec.encode(%{saved | native_branch_history: %{"different" => proof}})
      refute NativeBranchAuthority.history_valid?(%{saved | backend_assignment: nil})

      assert {:ok, command} = Command.new(["true"])

      assert {:ok, command_spec} =
               ExecutionSpec.new(
                 scope: saved.scope,
                 id: "after-branch",
                 profile: profile,
                 artifact: saved.spec.artifact,
                 command: command
               )

      assert {:ok, command_fingerprint} =
               ExecutionSpec.fingerprint(command_spec, String.duplicate("k", 32))

      assert {:ok, execution} = Execution.new(command_spec, command_fingerprint, 1101)
      assert {:ok, _, attached} = MachineOps.attach(saved, execution, 1101)
      assert attached.created_machine.backend_identity.material_history == [proof]
      assert {:ok, <<"smolbox-record-v29\0", _::binary>> = command_bytes} = Codec.encode(attached)
      assert {:ok, ^attached} = Codec.decode(command_bytes)
    end
  end

  test "native admission freezes independent child authority and exact profile-plus-extra capacity in v30" do
    for hold <- [false, true] do
      original = source()
      assert {:ok, parent, child} = accept(original, hold)
      assert :ok = ManagedMachine.validate(parent)
      assert :ok = ManagedMachine.validate(child)
      authority = child.branch.native_authority
      request = authority.request
      assert NativeBranchAuthority.valid?(authority)
      assert NativeBranchAuthority.child?(child)
      assert request["source"] == original.observed_machine.backend_identity.receipt
      assert authority.source == ManagedMachine.key(original)
      assert request["child"]["hold"] == hold
      assert Map.has_key?(request, "initial_release") == not hold
      assert parent.created_machine == original.created_machine
      assert parent.active_branch == child.id and parent.branch_children == %{"leaf" => false}
      assert child.reservation == original.reservation

      assert child.branch.spec.policy.resources == %{
               slots: 1,
               cpus: 1,
               memory_mb: 512,
               disk_gb: 5
             }

      assert child.backend_assignment.binding == original.backend_assignment.binding
      assert Assignment.valid?(child.backend_assignment)
      assert BranchCreation.valid?(child.backend_assignment.creation)

      refute Request.valid?(
               %{"operation" => "create", "create" => child.backend_assignment.creation},
               1000,
               2
             )

      refute request["child"]["owner_token"] == request["source"]["owner_token"]
      refute request["child"]["incarnation"] == request["source"]["incarnation"]
      refute inspect(authority) =~ request["child"]["owner_token"]

      for record <- [parent, child] do
        assert {:ok, <<"smolbox-record-v30\0", body::binary>> = bytes} = Codec.encode(record)
        assert {:ok, ^record} = Codec.decode(bytes)

        for version <- 1..29,
            do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

        assert {:error, _} = Codec.decode(bytes <> "trailing")

        assert {:error, _} =
                 Codec.decode(
                   "smolbox-record-v30\0" <> :erlang.term_to_binary(record, compressed: 9)
                 )

        stripped = Map.delete(record, :native_branch_history)

        stripped =
          if stripped.branch,
            do: %{stripped | branch: Map.delete(stripped.branch, :native_authority)},
            else: stripped

        for version <- 1..29,
            do:
              assert(
                {:error, _} =
                  Codec.decode("smolbox-record-v#{version}\0" <> :erlang.term_to_binary(stripped))
              )
      end
    end
  end

  test "each resource shortfall rejects before source mutation and native bare observations cannot complete a child" do
    original = source()
    requested = spec(true)
    needed = %{slots: 3, cpus: 3, memory_mb: 1536, disk_gb: 9}

    for field <- Map.keys(needed) do
      capacity = Map.update!(needed, field, &(&1 - 1))

      assert {:error, _} =
               BranchOps.accept(
                 original,
                 requested,
                 String.duplicate("f", 64),
                 "owned-leaf",
                 capacity,
                 original.reservation,
                 1100
               )
    end

    assert {:ok, parent, child} = accept(original, true)
    assert {:ok, parent, sent} = BranchOps.advance(parent, child, :accepted, :dispatching, 1101)

    assert {:error, _} =
             BranchOps.advance(
               parent,
               sent,
               :dispatching,
               {:observed, original.observed_machine},
               1102
             )

    assert {:ok, unknown_parent, unknown} =
             BranchOps.advance(parent, sent, :dispatching, :unknown, 1102)

    assert unknown.reservation == child.reservation and unknown_parent.active_branch == child.id
    assert unknown.branch.native_authority == child.branch.native_authority
    assert {:error, _} = BranchOps.resolve(unknown_parent, unknown, :absent, :absent, 1103)
    assert {:error, _} = BranchOps.retire(unknown_parent, unknown, 1103)
    assert {:error, _} = BranchOps.release_storage(unknown_parent, unknown, 1103)
  end

  test "a fresh BEAM reads frozen native branch authority without native tooling" do
    assert {:ok, _, child} = accept(source(), false)
    assert {:ok, bytes} = Codec.encode(child)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-branch-authority-#{System.unique_integer([:positive])}"
      )

    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code =
      ~S/[path] = System.argv(); case path |> File.read!() |> SmolBox.Store.Codec.decode() do / <>
        ~S/{:ok, %{branch: %{native_authority: %{request: %{"initial_release" => _}}}}} -> IO.puts("fresh-branch"); / <>
        ~S/_ -> System.halt(1) end/

    assert {"fresh-branch\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end

  test "undispatched native cancellation retires the index and releases only the unentered reservation" do
    original = source()
    assert {:ok, parent, child} = accept(original, true)

    assert {:ok, parent, cancelled} =
             BranchOps.advance(parent, child, :accepted, :cancelled, 1101)

    assert cancelled.state == :deleted and cancelled.reservation == nil
    assert parent.active_branch == nil and parent.branch_children == %{"leaf" => true}

    assert parent.created_machine == original.created_machine and
             parent.observed_machine == original.observed_machine

    assert {:ok, bytes} = Codec.encode(cancelled)
    assert {:ok, ^cancelled} = Codec.decode(bytes)
    assert parent.native_branch_history == %{}
  end

  test "authority substitutions cannot change source handle receipt policy child incarnation or ready state" do
    assert {:ok, _parent, child} = accept(source(), false)

    for changed <- [
          put_in(child.branch.source, {child.scope, "other-source"}),
          put_in(
            child.branch.native_authority.request["source"]["owner_token"],
            String.duplicate("0", 64)
          ),
          put_in(child.branch.native_authority.request["approval"]["host_overhead_mb"], 128),
          put_in(
            child.branch.native_authority.request["child"]["incarnation"],
            String.duplicate("0", 32)
          ),
          put_in(child.branch.state, :ready)
        ],
        do: assert({:error, _} = ManagedMachine.validate(changed))
  end

  test "memory admission preserves both records and all three charges across idempotent retries" do
    store = start_supervised!(Memory)
    original = source()
    key = ManagedMachine.key(original)

    assert {:ok, _} =
             Memory.bind_backend(store, original.worker_id, original.backend_assignment.binding)

    assert {:ok, _} = Memory.claim_worker(store, original.worker_id, "owner", 1000, 10_000)
    {:ok, initial} = ManagedMachine.new(original.spec, original.fingerprint, 1000)
    assert {:ok, _} = Memory.machine(store, :accept, [initial, 10])
    assert {:ok, claimed} = Memory.machine(store, :claim, [key, "owner", 1000, 10_000])

    assert {:ok, reserved} =
             Memory.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {original.worker_id, original.machine_name, @capacity,
                original.backend_assignment},
               1000
             ])

    assert {:ok, running} =
             Memory.machine(store, :write, [
               key,
               Contract.guard(reserved),
               [
                 state: :running,
                 operation: nil,
                 phase: nil,
                 created_machine: original.created_machine,
                 observed_machine: original.observed_machine
               ],
               1001
             ])

    requested = spec(false)
    fingerprint = BranchSpec.fingerprint(requested, key, String.duplicate("k", 32))
    args = [key, requested, fingerprint, "owned-leaf", @capacity, 1100]
    assert {:ok, child} = Memory.machine(store, :branch_accept, args)
    assert {:ok, ^child} = Memory.machine(store, :branch_accept, args)

    assert {:ok, %{slots: 3, cpus: 3, memory_mb: 1536, disk_gb: 9}} =
             Memory.usage(store, running.worker_id)

    assert {:ok, parent} = Memory.machine(store, :fetch, [key])
    assert parent.active_branch == child.id

    assert {:error, _} =
             Memory.machine(store, :branch_advance, [
               key,
               Contract.guard(running),
               child.id,
               :accepted,
               :dispatching,
               1101
             ])

    assert {:ok, ^child} = Memory.machine(store, :fetch, [ManagedMachine.key(child)])

    assert {:ok, dispatched} =
             Memory.machine(store, :branch_advance, [
               key,
               Contract.guard(parent),
               child.id,
               :accepted,
               :dispatching,
               1101
             ])

    assert dispatched.branch.native_authority == child.branch.native_authority
    assert {:ok, parent} = Memory.machine(store, :fetch, [key])

    assert {:ok, uncertain} =
             Memory.machine(store, :branch_advance, [
               key,
               Contract.guard(parent),
               child.id,
               :dispatching,
               :unknown,
               1102
             ])

    assert uncertain.branch.state == :unknown
    assert uncertain.branch.native_authority == child.branch.native_authority
    assert {:ok, %{state: :unknown, active_branch: "leaf"}} = Memory.machine(store, :fetch, [key])

    assert {:ok, %{slots: 3, cpus: 3, memory_mb: 1536, disk_gb: 9}} =
             Memory.usage(store, running.worker_id)
  end
end
