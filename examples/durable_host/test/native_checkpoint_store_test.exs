defmodule SmolBox.DurableHost.NativeCheckpointStoreTest do
  use ExUnit.Case, async: false
  alias SmolBox.Backend.{Assignment, Binding}
  alias SmolBox.{Checkpoint, ManagedMachine, ManagedMachineSpec, Profile}
  alias SmolBox.DurableHost.{Database, Repo, Store}

  alias SmolBox.Embedded.{
    CaptureStagingCleanupReceipt,
    CheckpointContract,
    NativeCapture,
    NativeCaptureCleanup
  }

  alias SmolBox.Store.{Codec, Contract, NativeCaptureContract}

  setup do
    partition = "checkpoint-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    {:ok, store} = Store.new(Repo, partition, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      Database.query(store, "DELETE FROM smolbox_partitions WHERE partition=$1", [partition])
    end)

    %{store: store}
  end

  test "native capture history atomically retains current receipt and rejects crossed proof", %{
    store: store
  } do
    NativeCaptureContract.run(Store, store)
  end

  for state <- [:running, :stopped] do
    test "unknown capture resolves #{state} source with retained unknown artifact allowance", %{
      store: store
    } do
      NativeCaptureContract.unknown_resolution(Store, store, unquote(state))
    end
  end

  for advanced <- [false, true], state <- [:running, :stopped] do
    test "entered capture resolves advanced_head=#{advanced}, state=#{state} with source-only history and retained artifact allowance",
         %{store: store} do
      NativeCaptureContract.entered_resolution(Store, store, unquote(advanced), unquote(state))
    end
  end

  for disposition <- [:completed, :resolved, :deleted, :aborted] do
    test "native #{disposition} cleanup release binds exact source authority and atomically projects accounting",
         %{store: store} do
      NativeCaptureContract.cleanup_release(Store, store, unquote(disposition))
    end
  end

  for state <- [:running, :stopped] do
    test "pre-entry #{state} source proof and unchanged history persist atomically", %{
      store: store
    } do
      NativeCaptureContract.aborted_source_resolution(Store, store, unquote(state))
    end
  end

  test "native cleanup proof and released accounting roll back together", %{store: store} do
    record = NativeCaptureContract.entered_resolution(Store, store, false)
    capture = record.captures["resolve-1"]
    key = ManagedMachine.key(record)
    guard = Contract.guard(record)

    proof = %NativeCaptureCleanup{
      kind: :cleaned,
      receipt: %CaptureStagingCleanupReceipt{
        schema: 1,
        previous: capture.native_source_receipt,
        operation_id: capture.spec.id,
        request: NativeCapture.request(capture),
        stage_sha256: String.duplicate("e", 64)
      }
    }

    assert {:ok, usage} = Store.usage(store, record.worker_id)

    assert {:error, :injected} =
             Repo.transact(fn ->
               assert {:ok, _} =
                        Store.machine(store, :capture_release, [
                          key,
                          guard,
                          capture.spec.id,
                          proof,
                          1104
                        ])

               {:error, :injected}
             end)

    assert {:ok, ^record} = Store.machine(store, :fetch, [key])
    assert {:ok, ^usage} = Store.usage(store, record.worker_id)
  end

  for checkpointable <- [false, true] do
    test "native checkpoint reservation preserves checkpointable=#{checkpointable} and rolls back crossed projections",
         %{store: store} do
      {:ok, profile} = Profile.new("captured")

      {:ok, checkpoint} =
        Checkpoint.new(
          id: "idle-v1",
          sha256: String.duplicate("a", 64),
          architecture: "x86_64",
          platform: :linux,
          path: "/operator/idle.smolcheckpoint",
          profile: profile
        )

      {:ok, spec} =
        ManagedMachineSpec.new(
          scope: "checkpoint",
          id: "restored",
          artifact: Checkpoint.artifact(checkpoint),
          checkpointable: unquote(checkpointable),
          profile: profile
        )

      {:ok, fingerprint} = ManagedMachineSpec.fingerprint(spec, String.duplicate("k", 32))
      {:ok, record} = ManagedMachine.new(spec, fingerprint, 1000)

      assignment = %Assignment{
        version: 2,
        binding: %Binding{
          kind: :embedded,
          target_id: "worker",
          generation: String.duplicate("d", 32)
        },
        creation:
          %{
            "name" => "fresh-checkpoint",
            "owner_token" => String.duplicate("b", 64),
            "incarnation" => String.duplicate("c", 32),
            "source" => Checkpoint.artifact(checkpoint),
            "resources" => %{
              "cpus" => 1,
              "memory_mib" => 256,
              "storage_gib" => 1,
              "overlay_gib" => 1
            },
            "labels" => %{}
          }
          |> CheckpointContract.attach(spec)
      }

      key = ManagedMachine.key(record)

      assert {:ok, %{native_checkpoint_sources: 1, native_checkpointable: 1}} =
               Store.capabilities(store)

      assert {:ok, _} = Store.bind_backend(store, "worker", assignment.binding)
      assert {:ok, _} = Store.claim_worker(store, "worker", "owner", 1000, 10_000)
      assert {:ok, _} = Store.machine(store, :accept, [record, 10])
      assert {:ok, claimed} = Store.machine(store, :claim, [key, "owner", 1000, 10_000])

      guard = %{
        owner: claimed.claim_owner,
        generation: claimed.generation,
        version: claimed.version
      }

      capacity = Profile.resources(profile)
      crossed = put_in(assignment.creation["source"]["id"], "other-source")

      assert {:error, _} =
               Store.machine(store, :reserve, [
                 key,
                 guard,
                 {"worker", "fresh-checkpoint", capacity, crossed},
                 1000
               ])

      empty = Map.new(capacity, fn {key, _value} -> {key, 0} end)
      assert {:ok, ^empty} = Store.usage(store, "worker")
      assert {:ok, ^claimed} = Store.machine(store, :fetch, [key])

      assert {:error, :injected} =
               Repo.transact(fn ->
                 assert {:ok, _} =
                          Store.machine(store, :reserve, [
                            key,
                            guard,
                            {"worker", "fresh-checkpoint", capacity, assignment},
                            1000
                          ])

                 {:error, :injected}
               end)

      assert {:ok, ^empty} = Store.usage(store, "worker")
      assert {:ok, ^claimed} = Store.machine(store, :fetch, [key])

      assert {:ok, saved} =
               Store.machine(store, :reserve, [
                 key,
                 guard,
                 {"worker", "fresh-checkpoint", capacity, assignment},
                 1000
               ])

      assert saved.backend_assignment == assignment
      assert {:ok, ^capacity} = Store.usage(store, "worker")
      assert {:ok, [^saved], nil} = Store.backend_assignments(store, "worker", nil, 10)
      assert {:ok, bytes} = Codec.encode(saved)

      assert String.starts_with?(
               bytes,
               if(unquote(checkpointable),
                 do: "smolbox-record-v23\0",
                 else: "smolbox-record-v22\0"
               )
             )

      assert {:ok, ^saved} = Codec.decode(bytes)
    end
  end
end
