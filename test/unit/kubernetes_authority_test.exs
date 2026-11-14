defmodule SmolBox.KubernetesAuthorityTest do
  use ExUnit.Case, async: true
  alias SmolBox.{Error, ExecutionValidation, Machine}
  alias SmolBox.Kubernetes.{Assignment, CleanupProof, Config, Identity, Observation, Receipt}
  alias SmolBox.Kubernetes.RecordValidation
  alias SmolBox.Store.Codec
  alias SmolBox.Test.Kubernetes, as: Fixture

  setup do
    {:ok, config} = Fixture.config()
    {record, assignment} = Fixture.assigned(config)
    receipt = Fixture.ready_receipt(assignment)
    %{config: config, record: record, assignment: assignment, receipt: receipt}
  end

  test "creation intent is immutable, opaque, approved and separate from Embedded", c do
    assert Assignment.valid?(c.assignment)
    assert Assignment.approved?(c.assignment, c.config, c.record)
    assert RecordValidation.valid?(c.assignment, c.record)
    assert SmolBox.Backend.Assignment.record_valid?(c.record)
    assert {:ok, bytes} = Codec.encode(c.record)
    assert {:ok, restored} = Codec.decode(bytes)
    assert restored == c.record

    for version <- ["v2", "v10", "v16"] do
      assert {:error, %Error{}} =
               Codec.decode(
                 "smolbox-record-" <> version <> <<0>> <> :erlang.term_to_binary(c.record)
               )
    end

    refute SmolBox.Backend.Assignment.valid?(c.assignment)
    refute Assignment.valid?(%{})
    assert Config.binding(c.config) == c.assignment.binding

    manifest = Assignment.manifest(c.assignment)

    assert Map.delete(manifest["metadata"]["annotations"], "smolbox.io/intent") ==
             c.assignment.pod_intent["metadata"]["annotations"]

    assert manifest["metadata"]["annotations"]["smolbox.io/intent"] == c.assignment.intent_digest
    assert manifest["spec"]["restartPolicy"] == "Never"
    assert manifest["spec"]["automountServiceAccountToken"] == false
    assert [_workload] = manifest["spec"]["containers"]
    assert hd(manifest["spec"]["containers"])["image"] == hd(c.config.sources).reference

    for value <- [inspect(c.assignment), Jason.encode!(manifest)] do
      refute value =~ "private-command-value"
      refute value =~ "private-env-value"
      refute value =~ "private-credential-context"
    end

    for changed <- [
          %{c.assignment | pod_name: "another"},
          %{c.assignment | nonce: Fixture.digest()},
          %{
            c.assignment
            | pod_intent: put_in(c.assignment.pod_intent, ["spec", "hostNetwork"], true)
          },
          %{c.assignment | intent_digest: String.duplicate("f", 64)},
          Map.put(c.assignment, :extra, true)
        ] do
      refute Assignment.valid?(changed)
    end

    refute Assignment.record_matches?(c.assignment, %{c.record | worker_id: "another"})

    refute Assignment.record_matches?(c.assignment, %{
             c.record
             | fingerprint: String.duplicate("f", 64)
           })

    assert {:error, _} = Assignment.new(c.config, c.record, "another")

    assert {:error, _} =
             Assignment.new(c.config, %{Fixture.execution(c.config) | spec: nil}, "valid-name")

    assert {:error, _} = Assignment.new(c.config, Fixture.execution(c.config), "invalid/name")
  end

  test "a saved receipt may bind readiness once, without replacing the original incarnation", c do
    {:ok, created} = Receipt.created(c.assignment, "pod-original")
    assert Receipt.valid?(created)
    assert {:error, _} = Receipt.ready(nil, nil, nil, nil)
    assert Receipt.same_creation?(created, c.receipt)
    refute Receipt.same_incarnation?(created, c.receipt)
    assert Receipt.matches_assignment?(c.receipt, c.assignment)
    refute Receipt.same_creation?(c.receipt, %{c.receipt | pod_uid: "replacement"})

    refute Receipt.matches_assignment?(
             %{c.receipt | nonce: String.duplicate("f", 64)},
             c.assignment
           )

    assert {:error, %Error{category: :identity_conflict}} =
             Receipt.ready(
               c.receipt,
               "containerd://" <> String.duplicate("f", 64),
               c.receipt.image_id,
               c.receipt.observation
             )

    assert {:error, _} =
             Receipt.ready(
               created,
               c.receipt.container_id,
               "sha256:config-only",
               c.receipt.observation
             )

    assert {:error, _} =
             Receipt.ready(created, c.receipt.container_id, c.receipt.image_id, %{
               c.receipt.observation
               | pod_uid: "replacement"
             })

    assert {:error, _} =
             Receipt.ready(c.receipt, c.receipt.container_id, c.receipt.image_id, %{
               c.receipt.observation
               | observed_at_ms: 999
             })

    assert {:ok, refreshed} =
             Receipt.ready(c.receipt, c.receipt.container_id, c.receipt.image_id, %{
               c.receipt.observation
               | observed_at_ms: 1100
             })

    assert Receipt.same_incarnation?(c.receipt, refreshed)
  end

  test "node capture separates ownership from complete, fresh isolation qualification", c do
    observation = c.receipt.observation
    assert Observation.valid?(observation)
    assert Observation.matches?(observation, c.assignment.binding, c.receipt.pod_uid)
    assert Observation.dispatchable?(observation, c.assignment.binding, c.receipt.pod_uid, 1001)
    assert Observation.fresh?(observation, 1001)
    refute Observation.fresh?(observation, 999)
    refute Observation.fresh?(observation, 6001)

    for changed <- [
          %{observation | processes: []},
          %{observation | interfaces: []},
          %{observation | sandbox_ids: []},
          Map.put(observation, :extra, true)
        ] do
      refute Observation.valid?(changed)
    end

    for unqualified <- [
          %{observation | complete_history: false},
          %{observation | isolated: false}
        ] do
      assert Observation.valid?(unqualified)
      refute Observation.dispatchable?(unqualified, c.assignment.binding, c.receipt.pod_uid, 1001)
    end

    refute Observation.valid?(%{observation | isolated: nil})
    refute Observation.valid?(%{observation | complete_history: nil})

    [process] = observation.processes
    [interface] = observation.interfaces

    for changed <- [
          %{process | kvm: []},
          %{process | vm_directory: "arbitrary-path"},
          %{process | pid: 0},
          Map.put(process, :extra, true)
        ] do
      refute Observation.valid?(%{observation | processes: [changed]})
    end

    refute Observation.valid?(%{observation | interfaces: [%{interface | name: "enp0s1"}]})

    refute Observation.matches?(
             %{observation | guard_sha256: String.duplicate("b", 64)},
             c.assignment.binding,
             c.receipt.pod_uid
           )

    refute Observation.matches?(
             %{observation | processes: [%{process | exe_sha256: String.duplicate("b", 64)}]},
             c.assignment.binding,
             c.receipt.pod_uid
           )
  end

  test "machine comparisons preserve Pod/container and PID-birth authority", c do
    original = machine(c.assignment, c.receipt)
    assert Machine.same_incarnation?(original, original)
    assert ExecutionValidation.machine?(original, c.record)

    assert RecordValidation.valid?(c.assignment, %{
             c.record
             | created_machine: original,
               backend_receipt: c.receipt,
               backend_create_state: :dispatched
           })

    for changed <- [
          %{c.receipt | pod_uid: "replacement"},
          %{c.receipt | container_id: "containerd://" <> String.duplicate("f", 64)},
          %{c.receipt | observation: %{c.receipt.observation | observer_epoch: "new-observer"}}
        ] do
      refute Machine.same_incarnation?(original, machine(c.assignment, changed))
    end

    [process] = c.receipt.observation.processes

    reused = %{
      c.receipt
      | observation: %{c.receipt.observation | processes: [%{process | start_ticks: 888}]}
    }

    refute Machine.same_incarnation?(original, machine(c.assignment, reused))
    refute ExecutionValidation.machine?(%{original | created_at: 1000}, c.record)
    refute ExecutionValidation.machine?(%{original | state: :stopped}, c.record)

    refute RecordValidation.valid?(c.assignment, %{
             c.record
             | created_machine: %{original | backend_identity: nil}
           })

    refute Identity.valid?(%SmolBox.Embedded.Identity{receipt: nil})
    refute SmolBox.Embedded.Identity.matches?(original.backend_identity, c.assignment)
  end

  test "cleanup proof cannot collapse API absence into physical collection", c do
    proof = Fixture.cleanup_proof(c.receipt)
    assert CleanupProof.valid?(proof)
    assert CleanupProof.matches?(proof, c.receipt)
    assert CleanupProof.releasable?(proof, c.receipt)
    legacy = %{proof | version: 1}
    assert CleanupProof.valid?(legacy)
    refute CleanupProof.releasable?(legacy, c.receipt)
    assert CleanupProof.valid?(%{proof | version: 2})
    refute CleanupProof.releasable?(%{proof | version: 2}, c.receipt)
    refute CleanupProof.valid?(%{proof | version: 4})
    assert Identity.valid?(%Identity{receipt: c.receipt})

    unisolated = %{c.receipt | observation: %{c.receipt.observation | isolated: false}}
    assert Receipt.valid?(unisolated)
    assert CleanupProof.valid?(Fixture.cleanup_proof(unisolated))
    assert CleanupProof.matches?(Fixture.cleanup_proof(unisolated), unisolated)
    refute CleanupProof.matches?(proof, unisolated)
    incomplete = %{c.receipt | observation: %{c.receipt.observation | complete_history: false}}
    refute CleanupProof.valid?(Fixture.cleanup_proof(incomplete))
    refute CleanupProof.matches?(proof, incomplete)

    for changed <- [
          %{proof | api_absent: false},
          %{proof | complete_history: false},
          %{proof | terminated_processes: []},
          %{proof | absent_records: []},
          %{proof | absent_vm_directories: []},
          %{proof | absent_shares: []},
          %{proof | observer_epoch: "new-observer"},
          %{proof | observed_at_ms: 999},
          Map.put(proof, :extra, true)
        ] do
      refute CleanupProof.valid?(changed)
    end

    refute CleanupProof.matches?(proof, %{c.receipt | pod_uid: "replacement"})
    newer_capture = %{c.receipt | observation: %{c.receipt.observation | observed_at_ms: 1200}}
    assert Receipt.same_incarnation?(c.receipt, newer_capture)
    refute CleanupProof.matches?(proof, newer_capture)
    [process] = proof.terminated_processes
    refute CleanupProof.valid?(%{proof | terminated_processes: [%{process | start_ticks: 888}]})
  end

  defp machine(assignment, receipt),
    do: %Machine{
      name: assignment.pod_name,
      state: :running,
      created_at: nil,
      cpus: 2,
      memory_mb: 1024,
      storage_gb: 20,
      overlay_gb: 10,
      backend_identity: %Identity{receipt: receipt}
    }
end
