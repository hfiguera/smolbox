defmodule SmolBox.NativeVolumeAttemptTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.Binding
  alias SmolBox.Embedded.{JSON, Request, VolumeAuthority}
  alias SmolBox.{Error, Volume, VolumePolicy}
  alias SmolBox.Runtime.{Target, VolumeAttempt}
  alias SmolBox.Store.{Memory, VolumeContract, VolumeOps}

  defp fixture do
    {:ok, fixture} =
      File.read!("native/smolbox-protocol/fixtures/volume-authority.json") |> JSON.decode()

    fixture
  end

  defp record do
    {:ok, policy} = VolumePolicy.new("local", "/srv/smolvm/volumes")

    %{
      VolumeContract.record()
      | policy: policy,
        size_gb: 4,
        worker_volume_id: fixture()["request"]["intent"]["worker_volume_id"],
        native_authority: %VolumeAuthority{
          binding: %Binding{
            kind: :embedded,
            target_id: "worker",
            generation: String.duplicate("b", 32)
          }
        }
    }
  end

  defp worker do
    v = record()

    %Target{
      kind: :embedded,
      id: "worker",
      domain_binding: Map.from_struct(v.native_authority.binding),
      volume_policy: v.policy
    }
  end

  defp abort do
    %{
      "result" => "volume",
      "volume" => %{
        "status" => "aborted",
        "proof" =>
          Map.put(
            fixture()["outcome"]["volume"]["proof"],
            "operation_id",
            String.duplicate("d", 32)
          )
      }
    }
  end

  defp store do
    store = start_supervised!(Memory)
    v = record()
    {:ok, _} = Memory.bind_backend(store, v.worker_id, v.native_authority.binding)
    {:ok, _, _} = Memory.volume_accept(store, v, %{disk_gb: 4})
    {%{store: {Memory, store}, clock: SmolBox.Runtime.Clock}, store, v}
  end

  test "native volume fingerprint binds enrolled domain while HTTP fingerprint input stays unchanged" do
    worker = worker()
    v = record()
    options = [scope: v.scope, id: v.id, worker_id: v.worker_id, size_gb: v.size_gb]
    assert VolumeAttempt.authority(worker) == v.native_authority
    assert VolumeAttempt.bound?(worker, v)

    changed = %{
      worker
      | domain_binding: %{worker.domain_binding | generation: String.duplicate("f", 32)}
    }

    refute VolumeAttempt.bound?(changed, v)

    refute VolumeAttempt.fingerprint_input(worker, options) ==
             VolumeAttempt.fingerprint_input(changed, options)

    http = %{worker | kind: :http}
    assert VolumeAttempt.authority(http) == nil
    refute VolumeAttempt.bound?(http, v)

    assert VolumeAttempt.fingerprint_input(http, options) ==
             {"smolbox-volume-v1", Enum.sort(options), v.policy}
  end

  test "deduplicated native volume reads do not require a live operational owner or repeat cleanup" do
    {config, store, volume} = store()
    worker = worker()
    assert worker.connection == nil
    assert {:ok, ^volume} = VolumeAttempt.existing(config, worker, volume)
    changed = %{volume | fingerprint: String.duplicate("f", 64)}

    assert {:error, %{category: :identity_conflict}} =
             VolumeAttempt.existing(config, worker, changed)

    {:ok, intent, _} =
      Memory.volume_change(
        store,
        Volume.key(volume),
        volume.version,
        :resolve_delete,
        config.clock.now()
      )

    assert VolumeAttempt.repeated?(worker, intent, volume.version)
    refute VolumeAttempt.repeated?(worker, intent, intent.version)
    refute VolumeAttempt.repeated?(worker, intent, nil)
    assert {:ok, ^intent} = VolumeAttempt.existing(config, worker, volume)
    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, "worker")
  end

  test "explicit cleanup selects protected staging only after confirmed rejection before dispatch" do
    v = record()
    proof = abort()

    invoke = fn action ->
      send(self(), {:action, action})

      case action["action"] do
        "resolve_deletion" ->
          {:error,
           %Error{category: :identity_conflict, operation: :volume, evidence: :not_dispatched}}

        "abort_staging" ->
          {:ok, proof}
      end
    end

    assert {:ok, ^proof} = VolumeAttempt.cleanup(v, invoke)
    assert_received {:action, %{"action" => "resolve_deletion", "quiesced" => true}}
    assert_received {:action, %{"action" => "abort_staging", "quiesced" => true}}
    refute_received {:action, _}
  end

  test "uncertainty, deadline, conflict and retained provisioning never trigger another mutation" do
    v = record()

    for error <- [
          %Error{category: :identity_conflict, operation: :volume, evidence: :dispatch_uncertain},
          %Error{category: :expired, operation: :volume, evidence: :not_dispatched},
          %Error{
            category: :unsupported_capability,
            operation: :volume,
            evidence: :not_dispatched
          },
          %Error{category: :admission_exhausted, operation: :volume, evidence: :not_dispatched}
        ] do
      invoke = fn action ->
        send(self(), {:action, action})
        {:error, error}
      end

      assert {:error, ^error} = VolumeAttempt.cleanup(v, invoke)
      assert_received {:action, %{"action" => "resolve_deletion", "quiesced" => true}}
      refute_received {:action, _}
    end

    {:ok, ready, _} = VolumeOps.change(v, 1, {:complete_native, fixture()["outcome"]}, 1001)
    error = %Error{category: :identity_conflict, operation: :volume, evidence: :not_dispatched}

    assert {:error, ^error} =
             VolumeAttempt.cleanup(ready, fn action ->
               send(self(), {:action, action})
               {:error, error}
             end)

    assert_received {:action, %{"action" => "resolve_deletion", "quiesced" => true}}
    refute_received {:action, _}
  end

  test "managed completion persists native proof and keeps full accounting on uncertain cleanup" do
    {config, store, v} = store()

    assert {:ok, ready, :changed} =
             VolumeAttempt.finish(config, v, {:complete_native, fixture()["outcome"]})

    assert ready.native_authority.provision == fixture()["outcome"]["volume"]["proof"]

    assert {:ok, intent, :changed} =
             Memory.volume_change(
               store,
               Volume.key(v),
               ready.version,
               :delete,
               config.clock.now()
             )

    error = %Error{category: :unknown, operation: :volume, evidence: :dispatch_uncertain}
    assert {:ok, unknown, :changed} = VolumeAttempt.finish(config, intent, {:unknown, error})
    assert unknown.state == :unknown
    assert unknown.native_authority == ready.native_authority
    assert {:ok, %{disk_gb: 4}} = Memory.usage(store, "worker")

    assert {:error, %{category: :stale_version}} =
             VolumeAttempt.finish(config, intent, {:complete_native, abort()})
  end

  test "protected unready abort after explicit intent releases capacity and retains its proof tombstone" do
    {config, store, v} = store()

    {:ok, intent, :changed} =
      Memory.volume_change(store, Volume.key(v), 1, :resolve_delete, config.clock.now())

    assert {:ok, deleted, :changed} =
             VolumeAttempt.finish(config, intent, {:complete_native, abort()})

    assert deleted.native_authority.abort == abort()["volume"]["proof"]
    assert deleted.native_authority.provision == nil
    assert {:ok, %{disk_gb: 0}} = Memory.usage(store, "worker")
  end

  test "fenced cleanup may use reconciling channel but never quarantine observation admission" do
    for action <- ~w(resolve_deletion abort_staging) do
      request = %{
        "operation" => "volume",
        "request" => %{
          fixture()["request"]
          | "action" => %{"action" => action, "quiesced" => true}
        }
      }

      assert Request.reconciliation?(request)
      refute Request.observation?(request)
      refute Request.reconciliation?(put_in(request["request"]["action"]["quiesced"], false))
      refute Request.reconciliation?(put_in(request["request"]["root"], "/caller"))
    end

    for action <- ~w(provision delete qualify_deletion) do
      refute Request.reconciliation?(%{
               "operation" => "volume",
               "request" => %{fixture()["request"] | "action" => %{"action" => action}}
             })
    end
  end
end
