defmodule SmolBox.NativeCaptureCleanupBackendTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, EmbeddedCaptureCleanup, EmbeddedContext}
  alias SmolBox.Embedded.{Config, NativeCapture}
  alias SmolBox.Store.{Memory, NativeCaptureContract}

  defp capture do
    record = NativeCaptureContract.entered_resolution(Memory, start_supervised!(Memory), false)
    record.captures["resolve-1"]
  end

  defp budget,
    do: %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16_384}

  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp reply(capture, kind),
    do:
      {:ok,
       %{
         "result" =>
           if(kind == :aborted, do: "capture_staging_aborted", else: "capture_staging_cleaned"),
         "cleanup" => %{
           "schema" => 1,
           "previous" => capture.native_source_receipt,
           "operation_id" => capture.spec.id,
           "request" => NativeCapture.request(capture),
           "stage_sha256" => String.duplicate("e", 64)
         }
       }, empty(), nil}

  test "cleanup response binds original capture and rejects output, overlays and substituted result kinds" do
    capture = capture()
    previous = capture.native_source_receipt
    result = reply(capture, :cleaned)
    assert {:ok, proof} = EmbeddedCaptureCleanup.decode(nil, capture, previous, :cleaned, result)
    assert proof.receipt.previous == previous and proof.kind == :cleaned
    {:ok, outcome, output, nil} = result

    for invalid <- [
          {:ok, put_in(outcome, ["cleanup", "operation_id"], "foreign"), output, nil},
          {:ok, outcome, %{output | file: "artifact"}, nil},
          {:ok, outcome, output, %SmolBox.Error{category: :unknown, operation: :checkpoint}},
          reply(capture, :aborted),
          {:ok, Map.put(outcome, "extra", true), output, nil}
        ],
        do:
          assert(
            {:error, _} = EmbeddedCaptureCleanup.decode(nil, capture, previous, :cleaned, invalid)
          )
  end

  test "only exact pre-dispatch state permits abort selection for a transition-free resolved capture" do
    capture = %{capture() | native_transition: nil}
    parent = self()

    transfer = fn request, reduced ->
      send(parent, {:request, request["operation"], reduced.timeout_ms})

      case request["operation"] do
        "cleanup_capture_staging" ->
          {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"},
           empty(), nil}

        "abort_capture_staging" ->
          reply(capture, :aborted)
      end
    end

    assert {:ok, %{kind: :aborted}} =
             EmbeddedCaptureCleanup.transfer(
               nil,
               capture,
               capture.native_source_receipt,
               budget(),
               transfer
             )

    assert_receive {:request, "cleanup_capture_staging", first}
    assert_receive {:request, "abort_capture_staging", second}
    assert first <= 1000 and second <= first
  end

  test "uncertain cleanup is never followed by abort or replay" do
    capture = %{capture() | native_transition: nil}
    parent = self()
    context = %EmbeddedContext{config: struct(Config), server: self()}

    transfer = fn request, _ ->
      send(parent, {:request, request["operation"]})

      {:ok, %{"result" => "error", "code" => "state", "dispatch" => "may_have_dispatched"},
       empty(), nil}
    end

    assert {:error, %{evidence: :dispatch_uncertain}} =
             EmbeddedCaptureCleanup.transfer(
               context,
               capture,
               capture.native_source_receipt,
               budget(),
               transfer
             )

    assert_receive {:request, "cleanup_capture_staging"}
    refute_receive {:request, _}
  end

  test "fallback consumes the original deadline and cannot dispatch after it expires" do
    capture = %{capture() | native_transition: nil}
    parent = self()

    transfer = fn request, _ ->
      send(parent, {:request, request["operation"]})
      Process.sleep(20)

      {:ok, %{"result" => "error", "code" => "state", "dispatch" => "not_dispatched"}, empty(),
       nil}
    end

    assert {:error, %{category: :expired}} =
             EmbeddedCaptureCleanup.transfer(
               nil,
               capture,
               capture.native_source_receipt,
               %{budget() | timeout_ms: 5},
               transfer
             )

    assert_receive {:request, "cleanup_capture_staging"}
    refute_receive {:request, _}
  end

  test "disabled checkpoint descriptors reject before any cleanup request" do
    capture = capture()
    context = %EmbeddedContext{config: struct(Config), server: self()}

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedCaptureCleanup.prepare(context, capture, budget())

    assert {:error, %{evidence: :not_dispatched}} =
             SmolBox.Backend.Embedded.invoke(
               context,
               :cleanup_capture,
               [capture, false],
               budget()
             )

    refute SmolBox.Backend.HTTP.supports_operation?(nil, :cleanup_capture)
  end
end
