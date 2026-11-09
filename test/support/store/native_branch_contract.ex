defmodule SmolBox.Store.NativeBranchContract do
  @moduledoc false
  import ExUnit.Assertions
  alias SmolBox.{BranchPolicy, BranchSpec, ManagedMachine, ManagedMachineSpec, Profile}

  alias SmolBox.Backend.Assignment

  alias SmolBox.Embedded.{
    BranchCanonical,
    BranchCompletion,
    BranchPublication,
    BranchReleaseTransition,
    Identity,
    NativeBranchResult,
    NativeGrowth
  }

  alias SmolBox.Store.{BranchOps, Codec, Contract, NativeCaptureContract}

  @fixture Path.expand(
             "../../../native/smolbox-protocol/fixtures/branch-creation-v1.json",
             __DIR__
           )
  @external_resource @fixture
  @rows Jason.decode!(File.read!(@fixture))
  @capacity %{slots: 16, cpus: 32, memory_mb: 65_536, disk_gb: 1024}

  def fixture do
    receipt = hd(@rows)["request"]["source"]
    original = NativeCaptureContract.fixture()
    profile = %{original.spec.profile | host_overhead_mb: 128}
    spec = %{original.spec | profile: profile}
    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))

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

    observed = %{
      created
      | state: :running,
        backend_identity: %{created.backend_identity | pid_identity: [123, 456]}
    }

    record = %{
      original
      | spec: spec,
        fingerprint: fingerprint,
        machine_name: receipt["name"],
        worker_id: receipt["target_id"],
        backend_assignment: assignment,
        created_machine: created,
        observed_machine: observed,
        state: :running,
        reservation: Profile.resources(profile)
    }

    assert :ok = ManagedMachine.validate(record)
    record
  end

  def prepare(adapter, store, hold) do
    original = fixture()
    key = ManagedMachine.key(original)

    assert {:ok, _} =
             adapter.bind_backend(store, original.worker_id, original.backend_assignment.binding)

    assert {:ok, _} = adapter.claim_worker(store, original.worker_id, "owner", 1000, 10_000)
    {:ok, initial} = ManagedMachine.new(original.spec, original.fingerprint, 1000)
    assert {:ok, _} = adapter.machine(store, :accept, [initial, 10])
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1000, 10_000])

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {original.worker_id, original.machine_name, @capacity,
                original.backend_assignment},
               1000
             ])

    assert {:ok, _} =
             adapter.machine(store, :write, [
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

    {:ok, policy} =
      BranchPolicy.new(
        id: "branches",
        resources: %{slots: 1, cpus: 1, memory_mb: 384, disk_gb: 5}
      )

    {:ok, spec} = BranchSpec.new(id: "leaf", policy: policy, idle: true, hold: hold)
    fingerprint = BranchSpec.fingerprint(spec, key, String.duplicate("k", 32))

    assert {:ok, child} =
             adapter.machine(store, :branch_accept, [
               key,
               spec,
               fingerprint,
               "owned-leaf",
               @capacity,
               1100
             ])

    assert {:ok, parent} = adapter.machine(store, :fetch, [key])
    {parent, child, result(parent, child)}
  end

  # Entirely synthetic hash/correlation models adapted to the actual frozen
  # random admission request. They grant no engine enrollment or SDK authority.
  def result(parent, child) do
    request = child.branch.native_authority.request

    template =
      Enum.find(@rows, &(&1["completion"]["held"] == child.branch.spec.hold))["completion"]

    publication = publication(template["publication"], request)
    root = publication["change"]["child"]
    release = release(template["release"], publication, request)

    completion = %{
      template
      | "publication" => publication,
        "child" => if(release, do: release["receipt"], else: root)
    }

    completion = if release, do: Map.put(completion, "release", release), else: completion
    assert {:ok, completion} = BranchCompletion.from_wire(completion)
    assert {:ok, proof} = BranchPublication.from_wire(publication)
    assert {:ok, history} = NativeGrowth.transitions(parent)

    source = %{
      parent.observed_machine
      | backend_identity: %Identity{
          receipt: proof.receipt,
          transition: proof,
          material_history: history ++ [proof],
          pid_identity: [123, 456]
        }
    }

    child_history =
      if release, do: [elem(BranchReleaseTransition.from_wire(release), 1)], else: []

    identity = %Identity{
      receipt: completion.child,
      transition: List.last(child_history),
      material_history: if(child_history == [], do: nil, else: child_history),
      pid_identity: [234, 567]
    }

    observed = %{parent.observed_machine | name: child.machine_name, backend_identity: identity}
    result = %NativeBranchResult{completion: completion, source: source, child: observed}
    assert NativeBranchResult.valid?(result)
    assert NativeBranchResult.bound?(result, parent, child)
    result
  end

  def rehash_intent(intent) do
    Map.put(
      intent,
      "request_sha256",
      BranchCanonical.digest([
        "smolbox-initial-branch-admission-v1",
        "9f446ae00219148ca4a703914f44a8e2fab11655",
        "shared-materialized-ram",
        BranchCanonical.ordered(intent["source"], :receipt),
        BranchCanonical.ordered(intent["child"], :child),
        BranchCanonical.ordered(intent["approval"], :approval),
        BranchCanonical.ordered(intent["plan"], :plan),
        intent["source_pid"],
        intent["epoch"]
      ])
    )
  end

  defp publication(template, request) do
    intent = template["change"]["child_origin"]["intent"]

    intent = %{
      intent
      | "source" => request["source"],
        "child" => request["child"],
        "approval" => request["approval"]
    }

    intent = rehash_intent(intent)

    root =
      template["change"]["child"]
      |> Map.merge(Map.take(request["child"], ~w(name owner_token incarnation)))
      |> Map.merge(Map.take(request["source"], ~w(target_id domain_generation)))

    root =
      put_in(
        root,
        ~w(material chain_sha256),
        BranchCanonical.digest([
          "smolbox-material-origin-v2",
          BranchCanonical.ordered(BranchCanonical.origin(root), :receipt)
        ])
      )

    change = %{
      template["change"]
      | "child_origin" => %{template["change"]["child_origin"] | "intent" => intent},
        "child" => root
    }

    material = %{
      request["source"]["material"]
      | "revision" => request["source"]["material"]["revision"] + 1,
        "operation_id" => request["child"]["operation_id"],
        "request_sha256" => intent["request_sha256"]
    }

    material = %{
      material
      | "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-branch-source-transition-v1",
            BranchCanonical.ordered(change, :source_change),
            material["record_sha256"]
          ])
    }

    %{
      template
      | "previous" => request["source"],
        "receipt" => Map.put(request["source"], "material", material),
        "change" => change
    }
  end

  defp release(nil, _, _), do: nil

  defp release(template, publication, request) do
    root = publication["change"]["child"]

    change = %{
      template["change"]
      | "request" => request["initial_release"],
        "binding" => publication["change"]["child_origin"]
    }

    material = %{
      template["receipt"]["material"]
      | "operation_id" => request["initial_release"]["operation_id"],
        "request_sha256" => request["initial_release"]["request_sha256"]
    }

    material = %{
      material
      | "chain_sha256" =>
          BranchCanonical.digest([
            "smolbox-branch-child-release-v1",
            BranchCanonical.ordered(root, :receipt),
            BranchCanonical.ordered(change, :release_change),
            material["record_sha256"]
          ])
    }

    %{
      template
      | "previous" => root,
        "receipt" => Map.put(root, "material", material),
        "change" => change
    }
  end

  def complete(adapter, store, hold) do
    {parent, child, result} = prepare(adapter, store, hold)
    assert {:ok, usage} = adapter.usage(store, parent.worker_id)

    assert {:ok, %{slots: 3, cpus: 3, memory_mb: 1152, disk_gb: 9}} =
             adapter.usage(store, parent.worker_id)

    assert {:error, _} =
             advance(adapter, store, parent, child, :accepted, {:native_complete, result}, 1101)

    assert {:ok, sent} = advance(adapter, store, parent, child, :accepted, :dispatching, 1101)
    assert sent.branch.native_authority == child.branch.native_authority
    assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])

    assert {:error, _} =
             BranchOps.advance(
               parent,
               sent,
               :dispatching,
               {:native_complete, result},
               sent.branch.deadline_ms + 1
             )

    for invalid <- [
          result.completion,
          %{result | source: :absent},
          %{result | child: :absent},
          put_in(result.source.backend_identity.pid_identity, [123, 457]),
          put_in(result.child.backend_identity.pid_identity, nil),
          put_in(
            result.child.backend_identity.pid_identity,
            result.source.backend_identity.pid_identity
          ),
          put_in(result.source.cpus, 2),
          put_in(result.child.storage_gb, 2),
          put_in(result.child.backend_identity.receipt["incarnation"], String.duplicate("0", 32)),
          put_in(result.source.backend_identity.material_history, nil)
        ] do
      assert {:error, _} =
               advance(
                 adapter,
                 store,
                 parent,
                 child,
                 :dispatching,
                 {:native_complete, invalid},
                 1102
               )

      assert {:ok, ^parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert {:ok, ^sent} = adapter.machine(store, :fetch, [ManagedMachine.key(child)])
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:ok, saved} =
             advance(
               adapter,
               store,
               parent,
               child,
               :dispatching,
               {:native_complete, result},
               1102
             )

    assert {:ok, source} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert saved.branch.state == if(hold, do: :held, else: :ready)

    assert saved.created_machine.backend_identity.receipt ==
             result.completion.publication["change"]["child"]

    assert saved.created_machine.backend_identity.transition == nil
    assert saved.observed_machine == result.child
    assert source.created_machine == parent.created_machine

    assert source.active_branch == nil and source.operation == nil and
             source.branch_children == %{child.id => false}

    assert source.observed_machine == result.source

    assert source.native_branch_history[child.id].receipt ==
             result.completion.publication["receipt"]

    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)

    assert {:error, _} =
             advance(
               adapter,
               store,
               parent,
               child,
               :dispatching,
               {:native_complete, result},
               1103
             )

    for record <- [source, saved] do
      assert :ok = ManagedMachine.validate(record)
      assert Assignment.record_valid?(record)
      assert {:ok, <<"smolbox-record-v30\0", _::binary>> = bytes} = Codec.encode(record)
      assert {:ok, ^record} = Codec.decode(bytes)
    end

    {source, saved, result, usage}
  end

  def advance(adapter, store, parent, child, expected, change, now),
    do:
      adapter.machine(store, :branch_advance, [
        ManagedMachine.key(parent),
        Contract.guard(parent),
        child.id,
        expected,
        change,
        now
      ])

  def resolve_completed(adapter, store, hold) do
    {parent, child, result} = prepare(adapter, store, hold)
    assert {:ok, _} = advance(adapter, store, parent, child, :accepted, :dispatching, 1101)
    assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, uncertain} = advance(adapter, store, parent, child, :dispatching, :unknown, 1102)
    assert {:ok, parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert {:ok, usage} = adapter.usage(store, parent.worker_id)
    assert parent.state == :unknown and uncertain.branch.native_authority.completion == nil
    args = [ManagedMachine.key(parent), Contract.guard(parent), child.id]

    for invalid <- [
          nil,
          :absent,
          result.child,
          result.completion,
          %{result | source: parent.observed_machine}
        ] do
      assert {:error, _} =
               adapter.machine(store, :branch_resolve, args ++ [result.source, invalid, 1103])

      assert {:ok, ^parent} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
      assert {:ok, ^uncertain} = adapter.machine(store, :fetch, [ManagedMachine.key(child)])
      assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    end

    assert {:error, _} =
             advance(adapter, store, parent, child, :unknown, {:native_complete, result}, 1103)

    assert {:ok, saved} =
             adapter.machine(store, :branch_resolve, args ++ [result.source, result, 1103])

    assert saved.branch.state == if(hold, do: :held, else: :ready)
    assert saved.branch.native_authority.request == child.branch.native_authority.request
    assert saved.branch.native_authority.completion == result.completion
    assert {:ok, source} = adapter.machine(store, :fetch, [ManagedMachine.key(parent)])
    assert source.active_branch == nil and source.observed_machine == result.source
    assert source.created_machine == parent.created_machine
    assert {:ok, ^usage} = adapter.usage(store, parent.worker_id)
    {source, saved, result, usage}
  end
end
