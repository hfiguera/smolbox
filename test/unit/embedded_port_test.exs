defmodule SmolBox.Embedded.PortTest do
  use ExUnit.Case, async: false
  alias SmolBox.{Backend, Error}
  alias SmolBox.Backend.Budget
  alias SmolBox.Backend.Embedded, as: EmbeddedBackend
  alias SmolBox.Embedded.{Config, Health, Port, Protocol, Supervisor}
  alias SmolBox.Test.EmbeddedPackage, as: Package

  defp package(options \\ []) do
    config = Package.create(options)
    on_exit(fn -> File.rm_rf!(config.package_path) end)
    config
  end

  defp owner(config, activate \\ true) do
    pid = start_supervised!({Port, config})
    wait_until(fn -> match?({:ok, %{status: :reconciling}}, Port.health(pid)) end)
    if activate, do: assert(:ok == Port.activate(pid, Config.domain_binding(config)))
    pid
  end

  defp budget(timeout \\ 5000),
    do: %Budget{timeout_ms: timeout, max_request_bytes: 1_048_576, max_response_bytes: 16_777_216}

  defp wait_until(predicate, remaining \\ 500) do
    cond do
      predicate.() ->
        :ok

      remaining == 0 ->
        flunk("embedded owner did not reach expected state")

      true ->
        Process.sleep(10)
        wait_until(predicate, remaining - 1)
    end
  end

  test "current approved package rejects volume dispatch before any native request" do
    config = package(protocol_major: 2, backend: true)
    pid = owner(config)

    request = %{
      "operation" => "volume",
      "request" => %{
        "policy_id" => "local",
        "intent" => %{
          "worker_volume_id" => "sbv-" <> String.duplicate("a", 32),
          "size_gb" => 4
        },
        "action" => %{"action" => "provision"}
      }
    }

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, request, budget(), self())

    refute Enum.any?(Package.received(config), &(&1["type"] == "request"))
    assert :ok = Port.shutdown(pid)
    wait_until(fn -> match?({:ok, %{status: :stopped}}, Port.health(pid)) end)
  end

  test "unavailable notice quarantines admission without losing the current owner or terminal" do
    config = package(protocol_minor: 4)
    pid = owner(config)
    {:ok, %{epoch: epoch} = health} = Port.health(pid)
    assert Health.describe(config, health).protocol_version == %{major: 1, minor: 4}
    assert Health.describe(config, health).engine_limits == Protocol.limits(4)

    assert {:ok, handle} =
             Port.submit(pid, Package.command(config, "unavailable"), budget(), self())

    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, nil}}, 1000
    assert outcome["completion"] == "unknown" and outcome["observed_exit"] == nil
    wait_until(fn -> match?({:ok, %{status: :quarantined}}, Port.health(pid)) end)
    assert {:ok, %{epoch: ^epoch, status: :quarantined}} = Port.health(pid)
    assert is_port(:sys.get_state(pid).port)
    assert {:error, %Error{category: :identity_conflict}} = Port.quiesce(pid, epoch)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    assert Enum.count(Package.received(config), &Map.has_key?(&1, "launch")) == 1
    assert :ok = Port.shutdown(pid)
    wait_until(fn -> match?({:ok, %{status: :stopped}}, Port.health(pid)) end)
    assert Enum.any?(Package.received(config), &(&1["type"] == "shutdown"))
  end

  test "parity quarantine preserves observations through Call without restoring work or readiness" do
    config = package(protocol_major: 2, backend: true)
    pid = owner(config)
    {:ok, %{epoch: epoch}} = Port.health(pid)
    {:ok, reference} = EmbeddedBackend.reference(config, pid)

    assert {:ok, handle} =
             Port.submit(pid, Package.command(config, "unavailable"), budget(), self())

    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, nil}}, 1000
    assert outcome["completion"] == "unknown"
    wait_until(fn -> match?({:ok, %{status: :quarantined}}, Port.health(pid)) end)
    assert :ok = Port.quiesce(pid, epoch)
    assert {:ok, %{status: :quarantined, epoch: ^epoch}} = Port.health(pid)
    assert {:ok, %SmolBox.Health{}} = Backend.invoke(reference, :health, [])

    assert {:error, %Error{evidence: :not_dispatched}} =
             Backend.invoke(reference, :readiness, [])

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    assert {:ok, %{status: :quarantined, epoch: ^epoch}} = Port.health(pid)
    assert Enum.count(Package.received(config), &Map.has_key?(&1, "launch")) == 1
    assert :ok = Port.shutdown(pid)
  end

  test "supervision is explicit and mutations wait for exact domain reconciliation" do
    config = package()
    assert Package.received(config) == []
    supervisor = start_supervised!({Supervisor, config})
    [{Port, pid, :worker, [Port]}] = Elixir.Supervisor.which_children(supervisor)
    wait_until(fn -> match?({:ok, %{status: :reconciling}}, Port.health(pid)) end)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    assert {:error, %Error{category: :identity_conflict}} = Port.activate(pid, %{})
    inspect = %{"operation" => "inspect", "receipt" => Package.receipt(config)}
    assert {:ok, handle} = Port.submit(pid, inspect, budget(), self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, nil}}, 1000
    assert outcome["observation"]["state"] == "stopped"
    assert :ok = Port.activate(pid, Config.domain_binding(config))
    {:ok, health} = Port.health(pid)
    assert Health.describe(config, health).protocol_version == %{major: 1, minor: 3}
    assert Health.describe(config, health).engine_limits == Protocol.limits(3)
    assert [%{"config_mode" => 0o600} | _rest] = Package.received(config)
    assert {:error, %Error{category: :identity_conflict}} = GenServer.start(Port, config)
  end

  test "package tampering and a mismatched Hello never authorize requests" do
    config = package()
    File.write!(Config.executable(config), "tampered", [:append])
    pid = start_supervised!({Port, config})
    wait_until(fn -> match?({:ok, %{status: :unavailable}}, Port.health(pid)) end)
    assert Package.received(config) == []

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    stop_supervised!(Port)

    other = package(wrong_hello: true)
    pid = start_supervised!({Port, other})
    wait_until(fn -> match?({:ok, %{status: :quarantined}}, Port.health(pid)) end)
    refute Enum.any?(Package.received(other), &(&1["type"] in ["approve", "request"]))
  end

  test "approved manifest version binds Hello and unsupported metadata cannot launch" do
    legacy = package()
    path = Path.join(legacy.package_path, "package.json")

    manifest =
      Jason.encode!(%{
        "schema" => 2,
        "identity" => legacy.package_identity,
        "policy" => %{"port_protocol_minor" => 4}
      })

    File.write!(path, manifest)
    config = %{legacy | package_manifest_sha256: Package.hash(manifest)}
    pid = start_supervised!({Port, config})
    wait_until(fn -> match?({:ok, %{status: :quarantined}}, Port.health(pid)) end)
    refute Enum.any?(Package.received(config), &(&1["type"] in ["approve", "request"]))
    stop_supervised!(Port)

    for policy <- [%{}, %{"port_protocol_minor" => 5}] do
      current = package(protocol_minor: 4)

      manifest =
        Jason.encode!(%{
          "schema" => 2,
          "identity" => current.package_identity,
          "policy" => policy
        })

      File.write!(Path.join(current.package_path, "package.json"), manifest)
      config = %{current | package_manifest_sha256: Package.hash(manifest)}
      pid = start_supervised!({Port, config})
      wait_until(fn -> match?({:ok, %{status: :unavailable}}, Port.health(pid)) end)
      assert Package.received(config) == []
      stop_supervised!(Port)
    end
  end

  test "epoch-fenced quiescence closes mutation admission until subscriptions drain" do
    config = package()
    pid = owner(config)
    {:ok, %{epoch: epoch}} = Port.health(pid)
    stale = String.duplicate("f", 32)
    refute stale == epoch
    assert {:error, %Error{category: :identity_conflict}} = Port.quiesce(pid, stale)
    assert {:ok, %{status: :ready}} = Port.health(pid)

    assert {:ok, handle} = Port.submit(pid, Package.command(config, "echo"), budget(), self())
    assert_receive {:smolbox_embedded, ^handle, {:terminal, _, nil}}, 1000
    assert {:error, %Error{category: :admission_exhausted}} = Port.quiesce(pid, epoch)
    assert {:ok, %{status: :reconciling}} = Port.health(pid)

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "hold"), budget(), self(), epoch)

    assert {:error, %Error{category: :admission_exhausted}} =
             Port.activate(pid, Config.domain_binding(config), epoch)

    assert :ok = Port.acknowledge(pid, handle, 10)
    assert :ok = Port.quiesce(pid, epoch)
    assert :ok = Port.activate(pid, Config.domain_binding(config), epoch)
    assert {:ok, %{status: :ready}} = Port.health(pid)
    assert Enum.count(Package.received(config), &(&1["type"] == "request")) == 1
  end

  test "binary stdout and stderr keep real exit evidence and terminal unread output charged" do
    config = package(limits: [in_flight: 1])
    pid = owner(config)
    assert {:ok, handle} = Port.submit(pid, Package.command(config, "echo"), budget(), self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, <<"out", 0, 255>>}}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stderr, <<"err", 0, 254>>}}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, nil}}, 1000
    assert outcome["observed_exit"] == 7
    assert outcome["output_bytes"] == 10

    assert {:error, %Error{category: :admission_exhausted}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    assert :ok = Port.acknowledge(pid, handle, 4)
    assert :ok = Port.acknowledge(pid, handle, 6)
    assert {:ok, next} = Port.submit(pid, Package.command(config, "hold"), budget(), self())
    assert :ok = Port.cancel(pid, next)
  end

  test "both event and byte credit require observer consumption while cancellation progresses" do
    config = package(limits: [initial_credit_events: 1, initial_credit_bytes: 2])
    pid = owner(config)
    assert {:ok, handle} = Port.submit(pid, Package.command(config, "flood"), budget(), self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, "x"}}, 1000
    refute_receive {:smolbox_embedded, ^handle, {:output, _, _}}, 50
    assert :ok = Port.acknowledge(pid, handle, 1)
    assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, "x"}}, 1000
    assert {:ok, other} = Port.submit(pid, Package.command(config, "hold"), budget(), self())
    assert_receive {:smolbox_embedded, ^other, :accepted}, 1000
    assert :ok = Port.cancel(pid, other)
    assert_receive {:smolbox_embedded, ^other, {:terminal, cancelled, %Error{}}}, 1000
    assert cancelled["observed_exit"] == nil
    assert :ok = Port.cancel(pid, handle)
    assert_receive {:smolbox_embedded, ^handle, {:terminal, _, %Error{}}}, 1000
    assert :ok = Port.acknowledge(pid, handle, 1)
  end

  test "deadline before admission does not reach the helper or consume an ID" do
    config = package()
    pid = owner(config)
    :sys.suspend(pid)
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :submitting)
        Port.submit(pid, Package.command(config, "echo"), budget(20), parent)
      end)

    assert_receive :submitting
    Process.sleep(50)
    :sys.resume(pid)
    assert {:error, %Error{category: :expired, evidence: :not_dispatched}} = Task.await(task)
    refute Enum.any?(Package.received(config), &(&1["type"] == "request"))
  end

  test "response budget disqualifies success without replacing native exit evidence" do
    config = package()
    pid = owner(config)
    limited = %{budget() | max_response_bytes: 150}
    assert {:ok, handle} = Port.submit(pid, Package.command(config, "echo"), limited, self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000

    assert_receive {:smolbox_embedded, ^handle,
                    {:terminal, outcome, %Error{category: :output_limit}}},
                   1000

    assert outcome["observed_exit"] == 7
    assert outcome["completion"] == "exited"
    refute_receive {:smolbox_embedded, ^handle, {:output, _, _}}, 50
  end

  @tag :deferred_crash
  test "caller death cancels only its request and an independent observer retains terminal" do
    config = package()
    pid = owner(config)
    parent = self()

    caller =
      spawn(fn ->
        result = Port.submit(pid, Package.command(config, "hold"), budget(), parent)
        send(parent, {:submitted, result})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:submitted, {:ok, handle}}, 1000
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert {:ok, other} = Port.submit(pid, Package.command(config, "echo"), budget(), self())
    Process.exit(caller, :kill)
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, %Error{}}}, 1000
    assert outcome["completion"] == "cancelled"
    assert outcome["observed_exit"] == nil
    assert_receive {:smolbox_embedded, ^other, {:terminal, %{"observed_exit" => 7}, nil}}, 1000
    assert :ok = Port.acknowledge(pid, other, 10)
  end

  @tag :deferred_crash
  test "observer death drains unread output and releases only the finished subscription" do
    config = package(limits: [in_flight: 1])
    pid = owner(config)

    observer =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    assert {:ok, _handle} = Port.submit(pid, Package.command(config, "echo"), budget(), observer)

    wait_until(fn ->
      match?({:message_queue_len, 4}, Process.info(observer, :message_queue_len))
    end)

    Process.exit(observer, :kill)
    wait_until(fn -> map_size(:sys.get_state(pid).records) == 0 end)
    assert {:ok, _next} = Port.submit(pid, Package.command(config, "hold"), budget(), self())
  end

  @tag :deferred_crash
  test "helper loss retains unread output and restarts with a fresh epoch and no replay" do
    config = package()
    pid = owner(config)
    {:ok, %{epoch: previous}} = Port.health(pid)
    assert {:ok, handle} = Port.submit(pid, Package.command(config, "crash"), budget(), self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stdout, _}}, 1000
    assert_receive {:smolbox_embedded, ^handle, {:output, :stderr, _}}, 1000

    assert_receive {:smolbox_embedded, ^handle,
                    {:channel_lost, %Error{evidence: :running_observed}}},
                   1000

    Process.sleep(1100)
    assert Enum.count(Package.received(config), &(&1["launch"] == true)) == 1
    assert :ok = Port.acknowledge(pid, handle, 10)
    wait_until(fn -> match?({:ok, %{status: :reconciling}}, Port.health(pid)) end)
    {:ok, %{epoch: fresh}} = Port.health(pid)
    refute fresh == previous
    assert Enum.count(Package.received(config), &(&1["type"] == "request")) == 1

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())

    refute_receive {:smolbox_embedded, ^handle, _event}, 50

    # Recovery against an old channel cannot activate this fresh helper.
    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Port.activate(pid, Config.domain_binding(config), previous)

    assert {:ok, %{status: :reconciling}} = Port.health(pid)
    assert :ok = Port.activate(pid, Config.domain_binding(config), fresh)

    count = Enum.count(Package.received(config), &(&1["type"] == "request"))
    last_id = :sys.get_state(pid).channel.last_id

    assert {:error, %Error{category: :identity_conflict, evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self(), previous)

    assert :sys.get_state(pid).channel.last_id == last_id
    assert Enum.count(Package.received(config), &(&1["type"] == "request")) == count

    assert {:ok, _fresh_handle} =
             Port.submit(pid, Package.command(config, "hold"), budget(), self(), fresh)
  end

  test "malformed sequencing, oversized headers, and partial EOF close without a terminal" do
    for mode <- ["bad_sequence", "huge_header", "partial"] do
      config = package()
      pid = owner(config)
      assert {:ok, handle} = Port.submit(pid, Package.command(config, mode), budget(), self())

      assert_receive {:smolbox_embedded, ^handle,
                      {:channel_lost, %Error{category: :protocol, evidence: :dispatch_uncertain}}},
                     1000

      refute_receive {:smolbox_embedded, ^handle, {:terminal, _, _}}, 50
      stop_supervised!(Port)
    end
  end

  test "file upload uses ordered bounded chunks and completion requires every declared byte" do
    config = package()
    pid = owner(config)

    operation = %{
      "operation" => "write_file",
      "receipt" => Package.receipt(config),
      "total_bytes" => 70_000,
      "options" => %{"guest_path" => "/workspace/file", "mode" => 0o600, "max_bytes" => 70_000}
    }

    assert {:ok, handle} = Port.submit(pid, operation, budget(), self())
    assert :ok = Port.upload(pid, handle, :binary.copy(<<0, 255>>, 32_768))
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    refute_receive {:smolbox_embedded, ^handle, {:terminal, _, _}}, 50
    assert :ok = Port.upload(pid, handle, :binary.copy("x", 4464))
    assert_receive {:smolbox_embedded, ^handle, {:terminal, outcome, nil}}, 1000
    assert outcome["observed_bytes"] == 70_000
    assert outcome["native_acknowledged"]
    assert [%{"total" => 70_000}] = Enum.filter(Package.received(config), & &1["upload_complete"])
  end

  test "unconfirmed helper shutdown quarantines instead of starting a second authority" do
    config = package(ignore_shutdown: true, limits: [shutdown_ms: 100])
    pid = owner(config)
    assert :ok = Port.shutdown(pid)
    wait_until(fn -> match?({:ok, %{status: :quarantined}}, Port.health(pid)) end)
    Process.sleep(1100)
    assert Enum.count(Package.received(config), &(&1["launch"] == true)) == 1

    assert {:error, %Error{evidence: :not_dispatched}} =
             Port.submit(pid, Package.command(config, "echo"), budget(), self())
  end

  @tag :deferred_crash
  test "supervised owner death is observed once and its replacement must reconcile" do
    config = package()
    supervisor = start_supervised!({Supervisor, config})
    [{Port, pid, :worker, [Port]}] = Elixir.Supervisor.which_children(supervisor)
    wait_until(fn -> match?({:ok, %{status: :reconciling}}, Port.health(pid)) end)
    :ok = Port.activate(pid, Config.domain_binding(config))
    monitor = Process.monitor(pid)
    directory = :sys.get_state(pid).directory
    assert {:ok, handle} = Port.submit(pid, Package.command(config, "hold"), budget(), self())
    assert_receive {:smolbox_embedded, ^handle, :accepted}, 1000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1000
    wait_until(fn -> not File.exists?(directory) end)

    wait_until(fn ->
      case Elixir.Supervisor.which_children(supervisor) do
        [{Port, replacement, :worker, [Port]}] when is_pid(replacement) and replacement != pid ->
          match?({:ok, %{status: :reconciling}}, Port.health(replacement))

        _restarting ->
          false
      end
    end)

    assert Enum.count(Package.received(config), &(&1["type"] == "request")) == 1
    refute_receive {:smolbox_embedded, ^handle, {:terminal, _, _}}, 50
  end
end
