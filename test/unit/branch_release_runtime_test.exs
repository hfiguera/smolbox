defmodule SmolBox.BranchReleaseRuntimeTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ManagedMachine, NetworkPolicy}

  alias SmolBox.Backend.{Budget, Reference}
  alias SmolBox.Runtime.{Branches, Target}
  alias SmolBox.Store.{BranchContract, Contract, MachineContract, Memory}
  alias SmolBox.Test.EmbeddedPackage

  defmodule Clock do
    def now, do: 1300
    def monotonic, do: System.monotonic_time(:millisecond)
  end

  defmodule StalledResolver do
    @behaviour SmolBox.BranchHTTPSCredentials
    @impl true
    def resolve(_, observer) do
      send(observer, {:resolver_started, self()})

      receive do
        :resolve -> {:ok, "child-test-key"}
      end
    end
  end

  # Keep real admission, deadlines and store transitions; no SDK or VM dispatch.
  defmodule Adapter do
    @behaviour SmolBox.Backend
    def supports_operation?(_, _), do: true
    def assign(context, _), do: {:ok, context}
    def invoke(_, :observe_health, _, _), do: {:ready, nil}
    def invoke(_, :branch_inspect_child, [child, true], _), do: {:ok, child.observed_machine}

    def invoke(observer, :branch_release, _, _) do
      send(observer, :release_dispatched)
      raise "stalled credentials must prevent release dispatch"
    end
  end

  defmodule Store do
    def machine({memory, observer}, :claim, arguments) do
      send(observer, {:release_claim, self()})
      Memory.machine(memory, :claim, arguments)
    end

    def machine({memory, observer}, :branch_release_advance, [_, _, _, change, _] = arguments) do
      send(observer, {:release_transition, change})
      Memory.machine(memory, :branch_release_advance, arguments)
    end
  end

  test "a stalled embedded credential resolver renews its lease and stops at the release deadline" do
    memory = start_supervised!(Memory)
    {:ok, network} = NetworkPolicy.new(hosts: ["api.example.test"])
    profile = %{MachineContract.record().spec.profile | network: network}
    source = MachineContract.running_named(Memory, memory, "source", [], profile, nil, true)
    spec = %{BranchContract.spec() | hold: true}
    {:ok, child} = BranchContract.accept(Memory, memory, source, spec)
    {:ok, _} = BranchContract.advance(Memory, memory, source, :accepted, :dispatching)
    observed = %{source.observed_machine | name: child.machine_name}

    {:ok, _} =
      BranchContract.advance(Memory, memory, source, :dispatching, {:observed, observed})

    {:ok, held} =
      BranchContract.advance(
        Memory,
        memory,
        source,
        :observed,
        {:complete, source.observed_machine}
      )

    key = ManagedMachine.key(held)
    {:ok, _} = Memory.machine(memory, :branch_release, [key, held.version, Clock.now()])
    {:ok, claimed} = Memory.machine(memory, :claim, [key, "owner", Clock.now(), 1000])

    {:ok, pending} =
      Memory.machine(memory, :write, [
        key,
        Contract.guard(claimed),
        [operation_deadline_ms: Clock.now() + 250],
        Clock.now()
      ])

    {:ok, usage} = Memory.usage(memory, source.worker_id)
    target = target(pending)

    config = %{
      workers: [target],
      store: {Store, {memory, self()}},
      clock: Clock,
      owner: "owner",
      lease_ms: 1000,
      poll_ms: 10
    }

    task = Task.async(fn -> Branches.release(config, pending) end)

    try do
      assert_receive {:resolver_started, resolver}, 1000
      caller = task.pid
      assert_receive {:release_claim, ^caller}, 1000
      assert_receive {:release_claim, ^caller}, 1000
      assert {:ok, {:ok, saved}} = Task.yield(task, 1000)
      refute Process.alive?(resolver)
      assert saved.branch.state == :unknown
      assert saved.branch.release_version == held.version
      assert_receive {:release_transition, :unknown}
      refute_receive {:release_transition, :dispatching}
      refute_receive :release_dispatched
      assert {:ok, ^saved} = Memory.machine(memory, :fetch, [key])
      assert {:ok, ^usage} = Memory.usage(memory, source.worker_id)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp target(child) do
    sdk = "native/policy-linux.json" |> File.read!() |> Jason.decode!() |> get_in(["sdk"])

    native =
      EmbeddedPackage.create(
        protocol_major: 2,
        platform: :linux,
        sdk_identity: sdk,
        smolvm_revision: sdk["source_revision"]
      )

    on_exit(fn -> EmbeddedPackage.remove!(native) end)

    native = %{
      native
      | profiles: [child.spec.profile],
        artifacts: [Map.merge(hd(native.artifacts), child.spec.artifact)],
        branch_policies: [child.branch.spec.policy],
        branch_https_credentials: {StalledResolver, self()}
    }

    reference = %Reference{
      adapter: Adapter,
      kind: :embedded,
      id: child.worker_id,
      context: self(),
      budget: %Budget{timeout_ms: 1000, max_request_bytes: 131_072, max_response_bytes: 131_072}
    }

    target = %{Target.normalize(native) | id: child.worker_id, connection: reference}
    assert Branches.approved?(target, child, child.branch.spec)
    target
  end
end
