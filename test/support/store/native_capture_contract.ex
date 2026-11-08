defmodule SmolBox.Store.NativeCaptureContract do
  @moduledoc false
  import ExUnit.Assertions

  alias SmolBox.Backend.{
    Assignment,
    Binding,
    EmbeddedCaptureObservation,
    EmbeddedContext
  }

  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureResolutionTransition,
    CaptureStagingCleanupReceipt,
    CaptureTransition,
    Identity,
    NativeCapture,
    NativeCaptureCleanup,
    NativeCaptureResolution,
    NativeGrowth
  }

  alias SmolBox.Runtime.NativeRecovery

  alias SmolBox.Store.{
    CaptureOps,
    Codec,
    Contract
  }

  alias SmolBox.{
    CheckpointCapture,
    CheckpointCaptureSpec,
    CheckpointPolicy,
    CheckpointResult,
    Machine,
    ManagedMachine,
    ManagedMachineSpec,
    Profile
  }

  defp capture_proofs do
    "../../../native/smolbox-protocol/fixtures/capture-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn wire ->
      {:ok, proof} = CaptureTransition.from_wire(wire)
      proof
    end)
  end

  def fixture do
    [first, _] = capture_proofs()
    receipt = first.previous
    {:ok, profile} = Profile.new("capture-history")

    artifact = %{
      "id" => "fixture",
      "sha256" => String.duplicate("d", 64),
      "architecture" => "aarch64"
    }

    {:ok, spec} =
      ManagedMachineSpec.new(
        scope: "native-capture",
        id: "vm",
        artifact: artifact,
        profile: profile,
        checkpointable: true
      )

    {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)

    created = %Machine{
      name: receipt["name"],
      state: :stopped,
      created_at: nil,
      cpus: profile.cpus,
      memory_mb: profile.memory_mb,
      storage_gb: 1,
      overlay_gb: 1,
      backend_identity: %Identity{receipt: receipt}
    }

    assignment = %Assignment{
      version: 2,
      binding: %Binding{
        kind: :embedded,
        target_id: receipt["target_id"],
        generation: receipt["domain_generation"]
      },
      creation: %{
        "name" => receipt["name"],
        "owner_token" => receipt["owner_token"],
        "incarnation" => receipt["incarnation"],
        "artifact" => %{
          "path" => "/fixture.smolmachine",
          "sha256" => artifact["sha256"],
          "max_bytes" => 1024,
          "guest_platform" => "linux/arm64"
        },
        "resources" => %{
          "cpus" => profile.cpus,
          "memory_mib" => profile.memory_mb,
          "storage_gib" => 1,
          "overlay_gib" => 1
        },
        "labels" => %{},
        "checkpointable" => true
      }
    }

    record = %{
      record
      | backend_assignment: assignment,
        worker_id: receipt["target_id"],
        worker_generation: 1,
        machine_name: receipt["name"],
        reservation: Profile.resources(profile),
        state: :stopped,
        operation: nil,
        phase: nil,
        created_machine: created,
        observed_machine: created
    }

    assert :ok = ManagedMachine.validate(record)
    record
  end

  def resolution_proofs do
    "../../../native/smolbox-protocol/fixtures/capture-resolutions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Enum.map(fn wire ->
      {:ok, proof} = CaptureResolutionTransition.from_wire(wire)
      proof
    end)
  end

  def aborted_source_resolution(adapter, store, state) do
    {_, _, sent, spec, _, _, _} = prepare(adapter, store, resolution_proofs())
    key = ManagedMachine.key(sent)
    assert {:ok, cancelled} = CaptureOps.cancel(sent, spec.id, 1102)

    assert {:ok, unknown} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :unknown, error: cancelled.captures[spec.id].error],
               1102
             ])

    wire =
      "../../../native/smolbox-protocol/fixtures/capture-abort-sources-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Enum.find(&(&1["state"] == Atom.to_string(state)))

    {:ok, proof} = CaptureAbortSourceQualification.from_wire(wire)

    observed = %{
      unknown.observed_machine
      | state: state,
        backend_identity: %{
          unknown.observed_machine.backend_identity
          | pid_identity: if(state == :running, do: [123, 456])
        }
    }

    resolution = %NativeCaptureResolution{
      observed: observed,
      qualification: proof
    }

    assert {:ok, usage} = adapter.usage(store, sent.worker_id)
    invalid = %{resolution | observed: %{observed | cpus: observed.cpus + 1}}

    assert {:error, _} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               invalid,
               1110
             ])

    assert {:ok, ^unknown} = adapter.machine(store, :fetch, [key])
    assert {:ok, ^usage} = adapter.usage(store, sent.worker_id)

    assert {:ok, saved} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               resolution,
               1110
             ])

    assert saved.captures[spec.id].native_abort_source == proof

    assert saved.captures[spec.id].result == nil and
             saved.captures[spec.id].native_transition == nil

    assert saved.captures[spec.id].state == :resolved_unknown and
             saved.captures[spec.id].released_at_ms == nil

    assert saved.observed_machine.backend_identity.receipt ==
             unknown.observed_machine.backend_identity.receipt

    assert saved.created_machine == unknown.created_machine and saved.active_capture == nil
    assert {:ok, projected} = adapter.usage(store, sent.worker_id)
    assert projected.disk_gb == sent.reservation.disk_gb + 1
    assert {:ok, <<"smolbox-record-v27\0", _::binary>> = encoded} = Codec.encode(saved)
    assert {:ok, ^saved} = Codec.decode(encoded)

    assert {:error, _} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               resolution,
               1111
             ])

    assert {:ok, ^saved} = adapter.machine(store, :fetch, [key])
    saved
  end

  def prepare(adapter, store, proofs \\ capture_proofs(), root \\ "/operator/captures") do
    assert {:ok, %{native_capture_histories: 1}} = adapter.capabilities(store)
    original = fixture()
    key = ManagedMachine.key(original)

    assert {:ok, _} =
             adapter.bind_backend(store, original.worker_id, original.backend_assignment.binding)

    assert {:ok, _} = adapter.claim_worker(store, original.worker_id, "owner", 1000, 10_000)
    {:ok, initial} = ManagedMachine.new(original.spec, original.fingerprint, 1000)
    assert {:ok, _} = adapter.machine(store, :accept, [initial, 10])
    assert {:ok, claimed} = adapter.machine(store, :claim, [key, "owner", 1000, 10_000])
    capacity = %{slots: 4, cpus: 8, memory_mb: 4096, disk_gb: 64}

    assert {:ok, reserved} =
             adapter.machine(store, :reserve, [
               key,
               Contract.guard(claimed),
               {original.worker_id, original.machine_name, capacity, original.backend_assignment},
               1000
             ])

    observed = %{
      original.created_machine
      | state: :running,
        backend_identity: %{original.created_machine.backend_identity | pid_identity: [123, 456]}
    }

    assert {:ok, running} =
             adapter.machine(store, :write, [
               key,
               Contract.guard(reserved),
               [
                 state: :running,
                 operation: nil,
                 phase: nil,
                 created_machine: original.created_machine,
                 observed_machine: observed
               ],
               1001
             ])

    [proof, crossed] = proofs

    {:ok, policy} =
      CheckpointPolicy.new(
        id: "private",
        root: root,
        max_bytes: 1_048_576,
        resources: %{slots: 1, cpus: 1, memory_mb: 256, disk_gb: 16}
      )

    {:ok, spec} =
      CheckpointCaptureSpec.new(
        id: proof.change["intent"]["operation_id"],
        policy: policy,
        idle: true
      )

    fingerprint = CheckpointCaptureSpec.fingerprint(spec, key, String.duplicate("k", 32))

    assert {:ok, accepted} =
             adapter.machine(store, :capture_accept, [key, spec, fingerprint, capacity, 1100])

    assert accepted.captures[spec.id].native_source_receipt ==
             running.observed_machine.backend_identity.receipt

    assert {:ok, sent} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(accepted),
               spec.id,
               :accepted,
               [state: :dispatching],
               1101
             ])

    assert {:ok, usage} = adapter.usage(store, original.worker_id)

    {original, running, sent, spec, proof, crossed, usage}
  end

  def run(adapter, store) do
    {original, running, sent, spec, proof, crossed, usage} = prepare(adapter, store)
    key = ManagedMachine.key(original)

    result = %CheckpointResult{
      path: CheckpointCapture.path(sent.captures[spec.id]),
      sha256: proof.change["artifact"]["sha256"],
      size_bytes: 512,
      profile: running.spec.profile,
      platform: :macos,
      architecture: "aarch64",
      runtime_version: "1.22.0"
    }

    assert {:error, _} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :captured, result: result, native_transition: crossed],
               1102
             ])

    assert {:ok, ^sent} = adapter.machine(store, :fetch, [key])
    assert {:ok, ^usage} = adapter.usage(store, original.worker_id)

    assert {:ok, saved} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :captured, result: result, native_transition: proof],
               1102
             ])

    assert saved.created_machine == running.created_machine
    assert saved.captures[spec.id].native_transition == proof
    assert saved.observed_machine.backend_identity.material_history == [proof]
    assert {:ok, <<"smolbox-record-v26\0", _::binary>> = bytes} = Codec.encode(saved)
    assert {:ok, ^saved} = Codec.decode(bytes)
    assert {:ok, ^usage} = adapter.usage(store, original.worker_id)
    saved
  end

  def entered_resolution(adapter, store, advanced, state \\ :stopped) do
    proofs = resolution_proofs()
    proofs = if advanced, do: Enum.reverse(proofs), else: proofs
    {original, _running, sent, spec, proof, crossed, usage} = prepare(adapter, store, proofs)
    assert {:ok, %{native_capture_resolutions: 1}} = adapter.capabilities(store)
    key = ManagedMachine.key(original)

    unknown = mark_unknown(adapter, store, key, sent, spec.id)

    observed = %{
      unknown.observed_machine
      | state: state,
        backend_identity: %Identity{
          receipt: proof.receipt,
          transition: proof,
          material_history: [proof],
          pid_identity: if(state == :running, do: proof.change["intent"]["source_pid"])
        }
    }

    assert NativeCapture.resolution_valid?(unknown, unknown.captures[spec.id], observed)
    assert NativeRecovery.observation_valid?(unknown, observed)

    for invalid <- [
          %{observed | state: :failed},
          %{observed | cpus: observed.cpus + 1},
          %{observed | backend_identity: %{observed.backend_identity | pid_identity: [123, 457]}},
          %{observed | backend_identity: %{observed.backend_identity | material_history: nil}},
          %{
            observed
            | backend_identity: %Identity{
                receipt: crossed.receipt,
                transition: crossed,
                material_history: [crossed]
              }
          }
        ] do
      assert {:error, _} =
               adapter.machine(store, :capture_resolve, [
                 key,
                 Contract.guard(unknown),
                 spec.id,
                 invalid,
                 1103
               ])

      assert {:ok, ^unknown} = adapter.machine(store, :fetch, [key])
      assert {:ok, ^usage} = adapter.usage(store, original.worker_id)
    end

    # Generic advancement cannot import source-only resolution authority.
    assert {:error, _} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(unknown),
               spec.id,
               :unknown,
               [state: :resolved_unknown, native_transition: proof, resolved_at_ms: 1103],
               1103
             ])

    assert {:ok, ^unknown} = adapter.machine(store, :fetch, [key])

    assert {:ok, resolved} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               observed,
               1103
             ])

    capture = resolved.captures[spec.id]
    assert resolved.state == state and resolved.active_capture == nil
    assert resolved.created_machine == original.created_machine
    assert capture.state == :resolved_unknown and capture.result == nil
    assert capture.native_transition == proof and capture.released_at_ms == nil
    assert resolved.observed_machine.backend_identity.material_history == [proof]
    receipt = proof.receipt

    assert {:ok, ^receipt, %{"storage_gib" => 1, "overlay_gib" => 1}, ^proof} =
             NativeGrowth.head(resolved)

    assert {:ok, [^proof]} = NativeGrowth.transitions(resolved)
    assert {:ok, after_usage} = adapter.usage(store, original.worker_id)
    assert after_usage.slots == original.reservation.slots
    assert after_usage.disk_gb == original.reservation.disk_gb + 1
    assert {:ok, <<"smolbox-record-v26\0", _::binary>> = encoded} = Codec.encode(resolved)
    assert {:ok, ^resolved} = Codec.decode(encoded)

    assert {:ok, ^resolved} =
             adapter.machine(store, :capture_accept, [
               key,
               spec,
               capture.fingerprint,
               %{slots: 4, cpus: 8, memory_mb: 4096, disk_gb: 64},
               1104
             ])

    resolved
  end

  def cleanup_release(adapter, store, disposition) do
    assert {:ok, %{native_capture_cleanup: 1}} = adapter.capabilities(store)

    {record, id, kind} =
      case disposition do
        :resolved ->
          record = entered_resolution(adapter, store, false)
          {record, "resolve-1", :cleaned}

        :aborted ->
          {_, _, sent, spec, _, _, _} = prepare(adapter, store)
          key = ManagedMachine.key(sent)

          assert {:ok, unknown} =
                   adapter.machine(store, :capture_advance, [
                     key,
                     Contract.guard(sent),
                     spec.id,
                     :dispatching,
                     [state: :unknown],
                     1102
                   ])

          assert {:ok, record} =
                   adapter.machine(store, :capture_resolve, [
                     key,
                     Contract.guard(unknown),
                     spec.id,
                     :absent,
                     1103
                   ])

          {record, spec.id, :aborted}

        other when other in [:completed, :deleted] ->
          captured = run(adapter, store)
          id = "capture-1"
          observed = if other == :deleted, do: :absent, else: captured.observed_machine

          assert {:ok, record} =
                   adapter.machine(store, :capture_resolve, [
                     ManagedMachine.key(captured),
                     Contract.guard(captured),
                     id,
                     observed,
                     1103
                   ])

          {record, id, :cleaned}
      end

    key = ManagedMachine.key(record)
    capture = record.captures[id]
    assert capture.native_source_receipt != nil and capture.released_at_ms == nil
    assert {:ok, before_usage} = adapter.usage(store, record.worker_id)

    proof = %NativeCaptureCleanup{
      kind: kind,
      receipt: %CaptureStagingCleanupReceipt{
        schema: 1,
        previous: capture.native_source_receipt,
        operation_id: id,
        request: NativeCapture.request(capture),
        stage_sha256: String.duplicate("e", 64)
      }
    }

    assert NativeCaptureCleanup.valid?(proof)

    assert {:error, _} =
             adapter.machine(store, :capture_release, [key, Contract.guard(record), id, 1104])

    for invalid <- [
          %{proof | kind: :foreign},
          %{proof | receipt: %{proof.receipt | operation_id: "foreign"}},
          %{
            proof
            | receipt: %{
                proof.receipt
                | previous:
                    Map.put(proof.receipt.previous, "owner_token", String.duplicate("f", 64))
              }
          },
          %{
            proof
            | receipt: %{proof.receipt | request: Map.put(proof.receipt.request, "max_bytes", 1)}
          },
          %{proof | receipt: %{proof.receipt | stage_sha256: "bad"}}
        ] do
      assert {:error, _} =
               adapter.machine(store, :capture_release, [
                 key,
                 Contract.guard(record),
                 id,
                 invalid,
                 1104
               ])

      assert {:ok, ^record} = adapter.machine(store, :fetch, [key])
      assert {:ok, ^before_usage} = adapter.usage(store, record.worker_id)
    end

    stale = Map.update!(Contract.guard(record), :version, &(&1 - 1))
    assert {:error, _} = adapter.machine(store, :capture_release, [key, stale, id, proof, 1104])

    assert {:ok, released} =
             adapter.machine(store, :capture_release, [
               key,
               Contract.guard(record),
               id,
               proof,
               1104
             ])

    assert released.captures[id].native_cleanup == proof and
             released.captures[id].released_at_ms == 1104

    assert released.captures[id].result == capture.result

    assert released.created_machine == record.created_machine and
             released.observed_machine == record.observed_machine

    assert {:ok, after_usage} = adapter.usage(store, record.worker_id)
    assert after_usage.disk_gb == before_usage.disk_gb - 1
    assert Map.delete(after_usage, :disk_gb) == Map.delete(before_usage, :disk_gb)
    assert {:ok, <<"smolbox-record-v26\0", _::binary>> = encoded} = Codec.encode(released)
    assert {:ok, ^released} = Codec.decode(encoded)

    assert {:ok, ^released} =
             adapter.machine(store, :capture_release, [
               key,
               Contract.guard(released),
               id,
               proof,
               1105
             ])

    changed = %{proof | receipt: %{proof.receipt | stage_sha256: String.duplicate("f", 64)}}

    assert {:error, _} =
             adapter.machine(store, :capture_release, [
               key,
               Contract.guard(released),
               id,
               changed,
               1105
             ])

    assert {:ok, ^after_usage} = adapter.usage(store, record.worker_id)
    released
  end

  defp mark_unknown(adapter, store, key, sent, id) do
    assert {:ok, record} =
             adapter.machine(store, :capture_advance, [
               key,
               Contract.guard(sent),
               id,
               :dispatching,
               [
                 state: :unknown,
                 error: %SmolBox.Error{
                   category: :unknown,
                   operation: :checkpoint,
                   evidence: :unknown
                 }
               ],
               1102
             ])

    record
  end

  def unknown_resolution(adapter, store, state) do
    {original, _running, sent, spec, proof, _crossed, usage} = prepare(adapter, store)
    key = ManagedMachine.key(original)

    unknown = mark_unknown(adapter, store, key, sent, spec.id)

    assert {:ok, identity} = NativeGrowth.current_identity(unknown)

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: identity,
      capture: unknown.captures[spec.id],
      history: []
    }

    wire = proof |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

    reply =
      {:ok, %{"result" => "capture_presence", "transition" => wire},
       %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

    assert {:ok, promoted} = EmbeddedCaptureObservation.promote(context, reply)

    observed = %{
      unknown.observed_machine
      | state: state,
        backend_identity: %{
          promoted.identity
          | pid_identity: if(state == :running, do: [123, 456], else: nil)
        }
    }

    assert NativeCapture.resolution_valid?(unknown, context.capture, observed)
    assert NativeRecovery.observation_valid?(unknown, observed)

    assert {:error, _} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               %{observed | cpus: observed.cpus + 1},
               1103
             ])

    assert {:ok, ^unknown} = adapter.machine(store, :fetch, [key])
    assert {:ok, ^usage} = adapter.usage(store, original.worker_id)

    assert {:ok, resolved} =
             adapter.machine(store, :capture_resolve, [
               key,
               Contract.guard(unknown),
               spec.id,
               observed,
               1103
             ])

    assert resolved.state == state and resolved.active_capture == nil
    assert resolved.created_machine == original.created_machine
    assert resolved.captures[spec.id].state == :resolved_unknown
    assert resolved.captures[spec.id].result == nil
    assert resolved.captures[spec.id].native_transition == proof
    assert resolved.observed_machine.backend_identity.material_history == [proof]
    assert resolved.captures[spec.id].released_at_ms == nil
    assert {:ok, after_usage} = adapter.usage(store, original.worker_id)
    assert after_usage.slots == original.reservation.slots
    assert after_usage.disk_gb == original.reservation.disk_gb + 1
    assert {:ok, <<"smolbox-record-v26\0", _::binary>> = encoded} = Codec.encode(resolved)
    assert {:ok, ^resolved} = Codec.decode(encoded)

    assert {:ok, ^resolved} =
             adapter.machine(store, :capture_accept, [
               key,
               spec,
               unknown.captures[spec.id].fingerprint,
               %{slots: 4, cpus: 8, memory_mb: 4096, disk_gb: 64},
               1104
             ])

    resolved
  end
end
