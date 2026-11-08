defmodule SmolBox.NativeCaptureAbortConsumptionTest do
  use ExUnit.Case, async: true

  alias SmolBox.Backend.{
    Budget,
    EmbeddedCaptureResolution,
    EmbeddedContext
  }

  alias SmolBox.Embedded.{
    CaptureAbortSourceQualification,
    CaptureStagingCleanupReceipt,
    NativeCaptureCleanup,
    NativeCaptureResolution
  }

  alias SmolBox.Store.{
    CaptureOps,
    Codec,
    CodecNativeCaptureAbortSources,
    Contract,
    Memory,
    NativeCaptureContract
  }

  alias SmolBox.{
    CheckpointCapture,
    ManagedMachine
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp proofs,
    do: @fixtures |> Path.join("capture-abort-sources-v1.json") |> File.read!() |> Jason.decode!()

  defp fixture do
    store = start_supervised!(Memory)

    {_, _, sent, spec, _, _, _} =
      NativeCaptureContract.prepare(Memory, store, NativeCaptureContract.resolution_proofs())

    assert {:ok, cancelled} = CaptureOps.cancel(sent, spec.id, 1102)

    assert {:ok, unknown} =
             Memory.machine(store, :capture_advance, [
               ManagedMachine.key(sent),
               Contract.guard(sent),
               spec.id,
               :dispatching,
               [state: :unknown, error: cancelled.captures[spec.id].error],
               1102
             ])

    {store, unknown, spec.id}
  end

  defp resolution(record, state) do
    wire = Enum.find(proofs(), &(&1["state"] == Atom.to_string(state)))
    {:ok, proof} = CaptureAbortSourceQualification.from_wire(wire)

    observed = %{
      record.observed_machine
      | state: state,
        backend_identity: %{
          record.observed_machine.backend_identity
          | pid_identity: if(state == :running, do: [123, 456])
        }
    }

    %NativeCaptureResolution{observed: observed, qualification: proof}
  end

  for state <- [:running, :stopped] do
    test "Memory atomically consumes #{state} unchanged-source qualification without releasing artifact capacity" do
      {store, unknown, id} = fixture()
      key = ManagedMachine.key(unknown)
      resolution = resolution(unknown, unquote(state))
      assert NativeCaptureResolution.valid?(resolution)
      assert {:ok, usage_before} = Memory.usage(store, unknown.worker_id)

      assert {:ok, saved} =
               Memory.machine(store, :capture_resolve, [
                 key,
                 Contract.guard(unknown),
                 id,
                 resolution,
                 1110
               ])

      capture = saved.captures[id]

      assert capture.state == :resolved_unknown and capture.result == nil and
               capture.native_transition == nil

      assert capture.native_abort_source == resolution.qualification
      assert capture.native_source_receipt == unknown.captures[id].native_source_receipt
      assert capture.native_cleanup == nil and capture.released_at_ms == nil
      assert saved.active_capture == nil and saved.operation == nil
      assert saved.created_machine == unknown.created_machine

      assert saved.observed_machine.backend_identity.receipt ==
               unknown.observed_machine.backend_identity.receipt

      assert saved.observed_machine.backend_identity.material_history ==
               unknown.observed_machine.backend_identity.material_history

      assert {:ok, usage} = Memory.usage(store, unknown.worker_id)

      assert usage.disk_gb == unknown.reservation.disk_gb + 1 and
               usage.disk_gb < usage_before.disk_gb

      assert {:ok, <<"smolbox-record-v27\0", body::binary>> = encoded} = Codec.encode(saved)
      assert {:ok, ^saved} = Codec.decode(encoded)

      for version <- 1..26,
          do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

      assert {:error, _} = Codec.decode(encoded <> "trailing")

      assert {:error, _} =
               Memory.machine(store, :capture_resolve, [
                 key,
                 Contract.guard(unknown),
                 id,
                 resolution,
                 1111
               ])

      assert {:ok, ^saved} = Memory.machine(store, :fetch, [key])

      assert {:error, _} =
               Memory.machine(store, :capture_release, [key, Contract.guard(saved), id, 1111])

      {:ok, receipt} = CaptureStagingCleanupReceipt.from_wire(resolution.qualification.cleanup)
      proof = %NativeCaptureCleanup{kind: :aborted, receipt: receipt}

      assert {:ok, released} =
               Memory.machine(store, :capture_release, [
                 key,
                 Contract.guard(saved),
                 id,
                 proof,
                 1112
               ])

      assert released.captures[id].native_abort_source == capture.native_abort_source
      assert released.captures[id].released_at_ms == 1112
      assert {:ok, %{disk_gb: disk}} = Memory.usage(store, unknown.worker_id)
      assert disk == unknown.reservation.disk_gb
    end
  end

  test "source qualification rejects inventory, crossed identity, process, proof and material without mutation" do
    {store, unknown, id} = fixture()
    good = resolution(unknown, :running)

    assert {:error, _} =
             Memory.machine(store, :capture_resolve, [
               ManagedMachine.key(unknown),
               Contract.guard(unknown),
               id,
               unknown.observed_machine,
               1110
             ])

    assert {:ok, ^unknown} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])

    for changed <- [
          %{good | observed: %{good.observed | cpus: good.observed.cpus + 1}},
          %{good | observed: %{good.observed | state: :stopped}},
          %{
            good
            | observed: %{
                good.observed
                | backend_identity: %{good.observed.backend_identity | pid_identity: [123, 457]}
              }
          },
          %{
            good
            | qualification: %{good.qualification | record_sha256: String.duplicate("f", 64)}
          },
          %{
            good
            | qualification: %{
                good.qualification
                | cleanup: Map.put(good.qualification.cleanup, "operation_id", "foreign")
              }
          }
        ] do
      assert {:error, _} =
               Memory.machine(store, :capture_resolve, [
                 ManagedMachine.key(unknown),
                 Contract.guard(unknown),
                 id,
                 changed,
                 1110
               ])

      assert {:ok, ^unknown} = Memory.machine(store, :fetch, [ManagedMachine.key(unknown)])
    end

    assert {:error, _} =
             CheckpointCapture.validate(%{
               unknown.captures[id]
               | native_abort_source: good.qualification
             })
  end

  test "v26 remains selective and omits new nil fields, rejecting field smuggling" do
    {_store, unknown, id} = fixture()
    assert {:ok, <<"smolbox-record-v26\0", body::binary>>} = Codec.encode(unknown)
    old = :erlang.binary_to_term(body)
    refute Map.has_key?(old.captures[id], :native_abort_source)
    assert {:ok, ^unknown} = Codec.decode("smolbox-record-v26\0" <> body)
    smuggled = put_in(old.captures[id], Map.put(old.captures[id], :native_abort_source, nil))
    assert {:error, _} = Codec.decode("smolbox-record-v26\0" <> :erlang.term_to_binary(smuggled))
    assert CodecNativeCaptureAbortSources.reader() == 1

    assert {:ok, %{native_capture_abort_sources: 1}} =
             Memory.capabilities(start_supervised!(Memory, id: :reader))
  end

  test "abort then qualification binds identical cleanup and consumes one deadline" do
    {_store, record, id} = fixture()

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: record.observed_machine.backend_identity,
      capture: record.captures[id]
    }

    wire = hd(proofs())
    parent = self()

    transfer = fn request, budget ->
      send(parent, {:request, request["operation"], budget.timeout_ms})

      outcome =
        case request["operation"] do
          "abort_capture_staging" ->
            %{"result" => "capture_staging_aborted", "cleanup" => wire["cleanup"]}

          "qualify_aborted_capture_source" ->
            %{"result" => "aborted_capture_source_qualified", "qualification" => wire}
        end

      {:ok, outcome, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    budget = %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}

    assert {:ok, ^context, proof} =
             EmbeddedCaptureResolution.qualify_aborted(
               context,
               budget,
               System.monotonic_time(:millisecond) + 1000,
               transfer
             )

    assert_receive {:request, "abort_capture_staging", first}
    assert_receive {:request, "qualify_aborted_capture_source", second}
    assert second <= first and first <= 1000

    assert {:ok, %NativeCaptureResolution{}} =
             EmbeddedCaptureResolution.finish(resolution(record, :running).observed, proof)

    assert {:error, _} =
             EmbeddedCaptureResolution.finish(resolution(record, :stopped).observed, proof)

    assert {:error, _} =
             EmbeddedCaptureResolution.qualify_aborted(
               context,
               budget,
               System.monotonic_time(:millisecond) - 1,
               transfer
             )

    refute_receive {:request, _, _}
  end

  test "uncertain abort, crossed cleanup and expired qualification never replay capture or unlock source" do
    {_store, record, id} = fixture()

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: record.observed_machine.backend_identity,
      capture: record.captures[id]
    }

    wire = hd(proofs())
    budget = %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}
    parent = self()

    for bad <- [
          {:ok, %{"result" => "error", "code" => "state", "dispatch" => "may_have_dispatched"},
           %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil},
          {:ok, %{"result" => "capture_staging_aborted", "cleanup" => wire["cleanup"]},
           %{stdout: "artifact", stderr: <<>>, file: <<>>}, nil},
          {:ok,
           %{
             "result" => "capture_staging_aborted",
             "cleanup" => Map.put(wire["cleanup"], "operation_id", "foreign")
           }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
        ] do
      send = fn request, _ ->
        send(parent, {:sent, request["operation"]})
        bad
      end

      assert {:error, _} =
               EmbeddedCaptureResolution.dispatch_resolution(
                 context,
                 budget,
                 System.monotonic_time(:millisecond) + 1000,
                 send
               )

      assert_receive {:sent, "abort_capture_staging"}
      refute_receive {:sent, _}
    end

    send = fn request, _ ->
      send(parent, {:sent, request["operation"]})

      case request["operation"] do
        "abort_capture_staging" ->
          {:ok,
           %{
             "result" => "capture_staging_aborted",
             "cleanup" => Map.put(wire["cleanup"], "stage_sha256", String.duplicate("f", 64))
           }, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}

        "qualify_aborted_capture_source" ->
          {:ok, %{"result" => "aborted_capture_source_qualified", "qualification" => wire},
           %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
      end
    end

    assert {:error, _} =
             EmbeddedCaptureResolution.dispatch_resolution(
               context,
               budget,
               System.monotonic_time(:millisecond) + 1000,
               send
             )

    assert_receive {:sent, "abort_capture_staging"}
    assert_receive {:sent, "qualify_aborted_capture_source"}
    refute_receive {:sent, _}
  end

  test "exact pre-dispatch refusal selects existing entered resolution without repeated abort" do
    {_store, record, id} = fixture()

    context = %EmbeddedContext{
      config: nil,
      server: self(),
      identity: record.observed_machine.backend_identity,
      capture: record.captures[id],
      history: []
    }

    resolution =
      "capture-resolutions-v1.json"
      |> then(&Path.join(@fixtures, &1))
      |> File.read!()
      |> Jason.decode!()
      |> hd()

    parent = self()

    send = fn request, _ ->
      send(parent, {:sent, request["operation"]})

      outcome =
        case request["operation"] do
          "abort_capture_staging" ->
            %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}

          "resolve_capture" ->
            %{"result" => "capture_resolved", "transition" => resolution}
        end

      {:ok, outcome, %{stdout: <<>>, stderr: <<>>, file: <<>>}, nil}
    end

    budget = %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}

    assert {:ok, promoted, nil} =
             EmbeddedCaptureResolution.dispatch_resolution(
               context,
               budget,
               System.monotonic_time(:millisecond) + 1000,
               send
             )

    assert promoted.identity.receipt == resolution["receipt"]
    assert_receive {:sent, "abort_capture_staging"}
    assert_receive {:sent, "resolve_capture"}
    refute_receive {:sent, _}
  end
end
