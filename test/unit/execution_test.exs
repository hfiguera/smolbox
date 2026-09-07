defmodule SmolBox.ExecutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SmolBox.{Command, Error, Execution, ExecutionSpec, Files, Machine, Profile, Result}
  alias SmolBox.Store.{Codec, RecordOps}

  defp record do
    {:ok, command} = Command.new(["python", "-c", "print('secret')"])
    {:ok, profile} = Profile.new("offline-v1")

    {:ok, spec} =
      ExecutionSpec.new(
        scope: "host",
        id: "id",
        command: command,
        profile: profile,
        artifact: %{
          "id" => "python",
          "architecture" => "aarch64",
          "sha256" => Files.sha256("image")
        }
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, :binary.copy(<<1>>, 32))
    {:ok, record} = Execution.new(spec, fingerprint, 1000)
    record
  end

  defp dispatching do
    record = record()

    assigned = %{
      record
      | worker_id: "worker",
        worker_generation: 1,
        machine_name: "owned",
        reservation: RecordOps.resources(record)
    }

    {:ok, preparing} = Execution.transition(assigned, [state: :preparing], 1100)
    {:ok, ready} = Execution.transition(preparing, [state: :ready], 1200)

    {:ok, dispatching} =
      Execution.transition(ready, [state: :dispatching, evidence: :dispatch_uncertain], 1300)

    dispatching
  end

  test "observed nonzero execution, collection and cleanup stay independent" do
    record = dispatching()
    result = %Result{exit_code: 7, stdout: <<255>>, stderr: ""}

    assert {:ok, collecting} =
             Execution.transition(
               record,
               [state: :collecting, evidence: :exited, result: result],
               1400
             )

    assert {:ok, done} =
             Execution.transition(collecting, [state: :completed, collection: :complete], 1500)

    assert Execution.terminal?(done)

    assert {:ok, cleanup_failed} =
             Execution.transition(
               done,
               [cleanup: :failed, last_error: %Error{category: :cleanup, operation: :delete}],
               1600
             )

    assert cleanup_failed.state == :completed
    assert cleanup_failed.result == result

    assert {:ok, retry} =
             Execution.transition(
               cleanup_failed,
               [cleanup: :in_progress, cleanup_attempts: 1],
               1700
             )

    assert retry.deadlines.cleanup == 1700 + record.spec.profile.cleanup_ms

    assert {:ok, cleaned} =
             Execution.transition(retry, [cleanup: :complete, absence_at_ms: 1800], 1800)

    assert {:error, _} = Execution.transition(cleaned, [cleanup: :pending], 1900)
    refute inspect(cleaned) =~ "secret"
    assert Execution.key(cleaned) == {"host", "id"}
  end

  property "uncertainty cannot transition back to any dispatch preparation state" do
    check all(
            future <- integer(2000..1_000_000),
            state <- member_of([:accepted, :preparing, :ready, :dispatching])
          ) do
      assert {:ok, unknown} =
               Execution.transition(dispatching(), [state: :unknown, evidence: :unknown], 1400)

      assert {:error, _} = Execution.transition(unknown, [state: state], future)
      assert {:ok, observed} = Execution.transition(unknown, [next_due_at_ms: future], future)
      assert observed.deadlines.execution == unknown.deadlines.execution
    end
  end

  test "termination without a receipt remains unknown and cannot restore a lost exit" do
    {:ok, cancelling} = Execution.transition(dispatching(), [state: :cancelling], 1400)

    assert {:ok, unknown} =
             Execution.transition(
               cancelling,
               [state: :unknown, evidence: :termination_confirmed],
               1500
             )

    assert unknown.result == nil
    refute Execution.terminal?(unknown)

    assert {:error, _} =
             Execution.transition(unknown, [state: :cancelled, evidence: :not_dispatched], 1600)

    assert {:error, _} = Execution.transition(unknown, [state: :completed], 1600)
  end

  test "state patches cannot alter identity or erase authoritative evidence" do
    record = dispatching()
    result = %Result{exit_code: 0, stdout: "", stderr: ""}

    {:ok, collecting} =
      Execution.transition(record, [state: :collecting, result: result, evidence: :exited], 1400)

    for changes <- [
          [scope: "foreign"],
          [version: 999],
          [generation: 100],
          [spec: record.spec],
          [state: :completed],
          [result: %{result | exit_code: 1}],
          [evidence: :unknown],
          [state: :accepted],
          [state: :completed, state: :completed],
          [artifacts: [self()]]
        ] do
      assert {:error, _} = Execution.transition(collecting, changes, 1500)
    end

    assert {:error, _} = Execution.transition(collecting, [], 1000)
    assert {:error, _} = Execution.transition(nil, [], 1500)
    assert {:error, _} = Execution.transition(record(), [state: :dispatching], 1500)
  end

  test "queue and first-entry stage deadlines survive repeated writes and storage round trips" do
    record = record()
    refute Execution.expired?(record, record.deadlines.queue - 1)
    assert Execution.expired?(record, record.deadlines.queue)

    assert {:ok, expired} =
             Execution.transition(record, [state: :expired], record.deadlines.queue)

    assert Execution.terminal?(expired)
    dispatched = dispatching()
    assert {:ok, bytes} = Codec.encode(dispatched)
    assert {:ok, restored} = Codec.decode(bytes)
    assert restored == dispatched
    assert {:ok, restored} = Execution.transition(restored, [next_due_at_ms: 3000], 3000)
    assert restored.deadlines == dispatched.deadlines
    assert {:error, _} = Codec.decode(bytes <> "trailing")

    assert {:error, _} =
             Codec.decode(
               "smolbox-record-v1\0" <> :erlang.term_to_binary(dispatched, compressed: 9)
             )

    assert {:error, _} = Codec.decode("smolbox-record-v1\0" <> <<131, 1, 2, 3>>)
    assert {:error, _} = Codec.decode("unknown-format")
  end

  test "durable decoding rejects live BEAM resources, unbounded manifests and unknown schemas" do
    record = record()

    invalid = [
      nil,
      %{record | spec: nil},
      record |> Map.delete(:spec) |> Map.put(:unexpected, :data),
      %{record | spec: record.spec |> Map.delete(:command) |> Map.put(:unexpected, :data)},
      %{
        record
        | spec: %{
            record.spec
            | command: record.spec.command |> Map.delete(:argv) |> Map.put(:unexpected, :data)
          }
      },
      %{
        record
        | spec: %{
            record.spec
            | profile: record.spec.profile |> Map.delete(:cpus) |> Map.put(:unexpected, :data)
          }
      },
      %{record | schema: 2},
      %{record | deadlines: %{queue: self()}},
      %{record | claim_owner: self()},
      %{record | result: self()},
      %{record | artifacts: [1 | :improper]},
      %{record | last_error: %{secret: "not permitted"}},
      Map.put(record, :pid, self()),
      %{record | spec: Map.put(record.spec, :callback, fn -> :secret end)},
      %{record | spec: %{record.spec | command: Map.put(record.spec.command, :pid, self())}},
      %{record | spec: %{record.spec | profile: Map.put(record.spec.profile, :secret, "x")}},
      %{record | reservation: %{slots: 1}},
      %{record | created_machine: self()}
    ]

    for value <- invalid do
      assert {:error, _} = Codec.encode(value)
      assert {:error, _} = Codec.decode("smolbox-record-v1\0" <> :erlang.term_to_binary(value))
    end

    assert {:error, _} = Execution.new(record.spec, "not-a-fingerprint", 0)
    assert {:error, _} = Execution.new(record.spec, record.fingerprint, -1)
  end

  test "cleanup requires absence after admission and creation evidence remains immutable" do
    record = record()
    profile = record.spec.profile

    machine = %Machine{
      name: "owned",
      state: :created,
      created_at: 1,
      cpus: 1,
      memory_mb: 256,
      storage_gb: 1,
      overlay_gb: 1
    }

    reserved = %{
      record
      | worker_id: "worker",
        worker_generation: 1,
        machine_name: "owned",
        created_machine: machine,
        reservation: %{
          slots: 1,
          cpus: 1,
          memory_mb: profile.memory_mb + profile.host_overhead_mb,
          disk_gb: 2
        }
    }

    assert :ok = Execution.validate(reserved)
    {:ok, reserved} = Execution.transition(reserved, [state: :cancelled], 1001)
    assert {:error, _} = Execution.transition(reserved, [cleanup: :complete], 1100)

    assert {:error, _} =
             Execution.transition(reserved, [created_machine: %{machine | created_at: 2}], 1100)

    assert {:ok, absent} =
             Execution.transition(reserved, [absence_at_ms: 1100, cleanup: :complete], 1100)

    assert {:error, _} = Execution.transition(absent, [absence_at_ms: nil], 1200)
  end

  test "persisted deadlines and error history enforce the same timestamp bounds" do
    record = record()
    failure = %Error{category: :store, operation: :store}
    latest = 253_402_300_000_000

    assert Execution.timestamp?(0)
    assert Execution.timestamp?(latest)

    assert :ok =
             Execution.validate(%{
               record
               | deadlines: Map.put(record.deadlines, :execution, latest),
                 errors: [%{at_ms: latest, error: failure}]
             })

    for invalid <- [-1, latest + 1, 1000.0, nil, self()] do
      refute Execution.timestamp?(invalid)

      assert {:error, %Error{category: :validation}} =
               Execution.validate(%{
                 record
                 | deadlines: Map.put(record.deadlines, :execution, invalid)
               })

      assert {:error, %Error{category: :validation}} =
               Execution.validate(%{record | errors: [%{at_ms: invalid, error: failure}]})
    end
  end

  test "a fresh BEAM can decode the fixed schema without interning atoms from stored bytes" do
    {:ok, bytes} = Codec.encode(dispatching())
    dir = Path.join(System.tmp_dir!(), "sbx-codec-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    file = Path.join(dir, "record.bin")
    File.write!(file, bytes)
    ebin = Application.app_dir(:smolbox, "ebin")

    script =
      "Code.ensure_loaded!(SmolBox.Store.Codec); [file] = System.argv(); case file |> File.read!() |> SmolBox.Store.Codec.decode() do {:ok, %{state: :dispatching}} -> IO.puts(\"fresh-ok\"); _ -> System.halt(1) end"

    assert {"fresh-ok\n", 0} =
             System.cmd("elixir", ["-pa", ebin, "-e", script, file], stderr_to_stdout: true)
  end

  test "artifact declarations and error history remain bounded in persisted records" do
    record = record()
    output = %{"path" => "/workspace/out", "destination" => "dest", "max_bytes" => 10}

    artifact = %{
      "path" => "/workspace/out",
      "destination" => "dest",
      "size" => 2,
      "sha256" => Files.sha256("ok")
    }

    record = %{record | spec: %{record.spec | outputs: [output]}}
    assert :ok = Execution.validate(%{record | artifacts: [artifact]})

    for artifacts <- [
          [artifact, artifact],
          [%{artifact | "size" => 100}],
          [%{artifact | "destination" => "foreign"}]
        ] do
      assert {:error, _} = Execution.validate(%{record | artifacts: artifacts})
    end

    failure = %Error{category: :store, operation: :store}

    record =
      Enum.reduce(1..12, record, fn count, record ->
        {:ok, next} = Execution.transition(record, [last_error: failure], 1000 + count)
        next
      end)

    assert Enum.count_until(record.errors, 9) == 8
    assert hd(record.errors).at_ms == 1012
    assert {:error, _} = Execution.validate(%{record | errors: [self()]})

    assert {:error, _} =
             Execution.validate(%{record | last_error: %{failure | operation: :unrecognized}})
  end
end
