defmodule SmolBox.NativeCaptureResolutionHistoryTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    CaptureResolutionTransition,
    CaptureTransition,
    Identity,
    MaterialHistory
  }

  alias SmolBox.Store.{Codec, MachineOps, Memory, NativeCaptureContract}

  alias SmolBox.{CheckpointCapture, Command, Execution, ExecutionSpec, ManagedMachine}

  for advanced <- [false, true], state <- [:running, :stopped] do
    test "entered resolution retains advanced_head=#{advanced}, state=#{state} with atomic source and resource projections" do
      NativeCaptureContract.entered_resolution(
        Memory,
        start_supervised!(Memory),
        unquote(advanced),
        unquote(state)
      )
    end
  end

  test "v25 rejects older envelope substitution, missing history and fake capture success" do
    record = NativeCaptureContract.entered_resolution(Memory, start_supervised!(Memory), true)

    record = %{
      record
      | captures:
          Map.new(record.captures, fn {id, capture} ->
            {id, %{capture | native_source_receipt: nil}}
          end)
    }

    assert {:ok, <<"smolbox-record-v25\0", body::binary>> = bytes} = Codec.encode(record)

    for version <- 1..24,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    identity = record.observed_machine.backend_identity
    refute Identity.valid?(%{identity | material_history: nil})

    assert {:error, _} =
             Codec.encode(put_in(record.observed_machine.backend_identity.material_history, nil))

    capture = record.captures["resolve-2"]

    for state <- [:captured, :completed, :dispatching, :unknown],
        do: assert({:error, _} = CheckpointCapture.validate(%{capture | state: state}))

    assert {:error, _} = Codec.encode(%{record | backend_assignment: nil})
    assert {:ok, ^record} = Codec.decode(bytes)
  end

  test "attached command inherits distinct source history without modifying original creation" do
    record = NativeCaptureContract.entered_resolution(Memory, start_supervised!(Memory), false)

    observed = %{
      record.observed_machine
      | state: :running,
        backend_identity: %{record.observed_machine.backend_identity | pid_identity: [321, 654]}
    }

    assert {:ok, running} =
             ManagedMachine.update(record, %{state: :running, observed_machine: observed}, 1200)

    {:ok, command} = Command.new(["true"])

    {:ok, spec} =
      ExecutionSpec.new(
        scope: record.scope,
        id: "after-resolution",
        profile: record.spec.profile,
        artifact: record.spec.artifact,
        command: command
      )

    {:ok, fingerprint} = ExecutionSpec.fingerprint(spec, String.duplicate("k", 32))
    {:ok, execution} = Execution.new(spec, fingerprint, 1201)
    assert {:ok, _, attached} = MachineOps.attach(running, execution, 1201)

    assert attached.created_machine.backend_identity.material_history == [
             record.captures["resolve-1"].native_transition
           ]

    assert running.created_machine == record.created_machine
    assert :ok = Execution.validate(attached)
    assert {:ok, <<"smolbox-record-v25\0", _::binary>> = bytes} = Codec.encode(attached)
    assert {:ok, ^attached} = Codec.decode(bytes)
  end

  test "a known absent head cannot become an unconstrained lineage placeholder" do
    [resolution_wire, capture_wire, bad_wire] =
      "../../native/smolbox-protocol/fixtures/capture-resolution-history-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, resolution} = CaptureResolutionTransition.from_wire(resolution_wire)
    assert {:ok, capture} = CaptureTransition.from_wire(capture_wire)
    assert {:ok, bad} = CaptureResolutionTransition.from_wire(bad_wire)
    sizes = %{"storage_gib" => 1, "overlay_gib" => 1}

    assert {:ok, receipt, ^sizes} =
             MaterialHistory.chain([resolution, capture], resolution.previous, sizes)

    assert receipt == capture.receipt
    assert :error = MaterialHistory.chain([resolution, bad], resolution.previous, sizes)
    assert :error = MaterialHistory.chain([resolution, resolution], resolution.previous, sizes)
    assert :error = MaterialHistory.chain([capture, resolution], resolution.previous, sizes)

    assert Identity.valid?(%Identity{
             receipt: receipt,
             transition: capture,
             material_history: [resolution, capture]
           })

    refute Identity.valid?(%Identity{
             receipt: bad.receipt,
             transition: bad,
             material_history: [resolution, bad]
           })
  end

  test "fresh BEAM loads the v25 resolution vocabulary before safe decoding" do
    record = NativeCaptureContract.entered_resolution(Memory, start_supervised!(Memory), true)
    assert {:ok, bytes} = Codec.encode(record)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-native-resolution-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{captures: %{"resolve-2" => %{state: :resolved_unknown, result: nil,
        native_transition: %{__struct__: SmolBox.Embedded.CaptureResolutionTransition}}}}} -> IO.puts("fresh-resolution")
      _ -> System.halt(1)
    end
    """

    assert {"fresh-resolution\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
