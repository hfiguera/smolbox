defmodule SmolBox.NativeExportHistoryTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{ExportAuthority, ExportStageCleanup}
  alias SmolBox.Store.{Codec, ExportContract, ExportOps, Memory, NativeExportContract}

  alias SmolBox.{
    Error,
    Export,
    ExportDestination,
    ExportReceipt,
    ExportResult,
    ManagedMachine
  }

  defp fixture, do: NativeExportContract.fixture()

  test "Memory atomically retains unknown reservations and releases only matching cleanup" do
    NativeExportContract.lifecycle(
      Memory,
      start_supervised!(Memory)
    )
  end

  defp dispatch do
    {original, accepted, spec, request, proof} = fixture()

    assert {:ok, sent} =
             ExportOps.advance(
               accepted,
               spec.id,
               :accepted,
               [state: :dispatching, native_request: request],
               1101
             )

    {original, sent, spec, request, proof}
  end

  defp receipt(proof),
    do: %ExportReceipt{
      manifest_sha256: proof.identity["manifest_sha256"],
      size_bytes: proof.identity["size_bytes"],
      platform: proof.identity["platform"],
      native_publication: proof
    }

  test "acceptance freezes enrolled source; dispatch requires an immutable bounded request" do
    {original, accepted, spec, request, _proof} = fixture()
    export = accepted.exports[spec.id]
    assert %ExportAuthority{source: source, request: nil} = export.native_authority
    assert source == original.created_machine.backend_identity.receipt
    refute inspect(export.native_authority) =~ source["owner_token"]

    assert {:error, _} =
             ExportOps.advance(accepted, spec.id, :accepted, [state: :dispatching], 1101)

    for {field, value} <- [
          {"request_sha256", String.duplicate("f", 64)},
          {"destination_id", "other"},
          {"tag", "other"},
          {"max_staging_bytes", 549_755_813_888}
        ] do
      assert {:error, _} =
               ExportOps.advance(
                 accepted,
                 spec.id,
                 :accepted,
                 [state: :dispatching, native_request: Map.put(request, field, value)],
                 1101
               )
    end

    assert {:ok, sent} =
             ExportOps.advance(
               accepted,
               spec.id,
               :accepted,
               [state: :dispatching, native_request: request],
               1101
             )

    assert sent.exports[spec.id].native_authority.source == source

    assert {:error, _} =
             ExportOps.advance(
               sent,
               spec.id,
               :dispatching,
               [
                 state: :unknown,
                 native_request: Map.put(request, "destination_sha256", String.duplicate("f", 64))
               ],
               1102
             )

    assert {:ok, unknown} = ExportOps.cancel(sent, spec.id, 1102)
    assert unknown.exports[spec.id].native_authority == sent.exports[spec.id].native_authority
    assert Export.resources(unknown) == spec.destination.resources
  end

  test "only exact native acknowledgement advances verification and it grants no cleanup" do
    {_original, sent, spec, _request, proof} = dispatch()
    receipt = receipt(proof)

    assert {:error, _} =
             ExportOps.advance(
               sent,
               spec.id,
               :dispatching,
               [state: :verifying, receipt: %{receipt | native_publication: nil}],
               1102
             )

    assert {:ok, verifying} =
             ExportOps.advance(
               sent,
               spec.id,
               :dispatching,
               [state: :verifying, receipt: receipt],
               1102
             )

    result = %ExportResult{
      reference:
        ExportDestination.reference(spec.destination, "sha256:" <> receipt.manifest_sha256),
      manifest_sha256: receipt.manifest_sha256,
      size_bytes: receipt.size_bytes,
      platform: receipt.platform,
      architecture: "x86_64",
      config_sha256: proof.identity["config_sha256"],
      content_sha256: proof.identity["content_sha256"],
      verified_at_ms: 1103,
      runtime_version: "1.22.0"
    }

    assert {:error, _} =
             ExportOps.advance(
               verifying,
               spec.id,
               :verifying,
               [state: :published, result: %{result | content_sha256: String.duplicate("0", 64)}],
               1103
             )

    assert {:ok, published} =
             ExportOps.advance(
               verifying,
               spec.id,
               :verifying,
               [state: :published, result: result],
               1103
             )

    assert {:error, _} = ExportOps.resolve(published, spec.id, published.observed_machine, 1104)
    assert {:error, _} = ExportOps.resolve(published, spec.id, :absent, 1104)
    assert Export.resources(published) == spec.destination.resources

    assert {:ok, ^published} =
             Codec.encode(published) |> then(fn {:ok, bytes} -> Codec.decode(bytes) end)

    cleanup_wire =
      "../../native/smolbox-protocol/fixtures/export-cleanups-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> hd()

    {:ok, cleanup} = ExportStageCleanup.from_wire(cleanup_wire)

    assert {:ok, completed} =
             ExportOps.resolve(published, spec.id, published.observed_machine, cleanup, 1104)

    assert completed.exports[spec.id].state == :completed
    assert completed.exports[spec.id].result == result
    assert completed.exports[spec.id].receipt == receipt
    assert Export.resources(completed).disk_gb == 0
  end

  test "v28 is selective, rejects earlier envelopes and forbids authority adoption" do
    {original, sent, spec, _request, proof} = dispatch()
    assert {:ok, <<"smolbox-record-v28\0", body::binary>> = bytes} = Codec.encode(sent)
    assert {:ok, ^sent} = Codec.decode(bytes)

    for version <- 1..27,
        do: assert({:error, _} = Codec.decode("smolbox-record-v#{version}\0" <> body))

    assert {:error, _} = Codec.decode(bytes <> "trailing")
    export = sent.exports[spec.id]

    for authority <- [
          nil,
          %{
            export.native_authority
            | source: put_in(proof.source, ["owner_token"], String.duplicate("f", 64))
          }
        ] do
      invalid = %{sent | exports: %{spec.id => %{export | native_authority: authority}}}
      assert {:error, _} = ManagedMachine.validate(invalid)
      assert {:error, _} = Codec.encode(invalid)
    end

    assert {:ok, old} = Codec.encode(original)
    refute String.starts_with?(old, "smolbox-record-v28\0")
    assert {:ok, ^original} = Codec.decode(old)

    assert {:ok, failed} =
             ExportOps.advance(
               sent,
               spec.id,
               :dispatching,
               [
                 state: :failed,
                 error: %Error{
                   category: :unsupported_capability,
                   operation: :export,
                   evidence: :not_dispatched
                 }
               ],
               1102
             )

    assert failed.active_export == nil
    assert failed.exports[spec.id].native_authority == export.native_authority
  end

  test "legacy HTTP export bytes omit native defaults and reject their presence" do
    store = start_supervised!(Memory)
    machine = ExportContract.stopped(Memory, store)

    assert {:ok, accepted} =
             ExportContract.accept(Memory, store, machine)

    id = accepted.active_export
    assert {:ok, sent} = ExportOps.advance(accepted, id, :accepted, [state: :dispatching], 1101)
    {_, _, _, _, proof} = fixture()
    receipt = %{receipt(proof) | native_publication: nil}

    assert {:ok, verifying} =
             ExportOps.advance(
               sent,
               id,
               :dispatching,
               [state: :verifying, receipt: receipt],
               1102
             )

    assert {:ok, <<"smolbox-record-v11\0", body::binary>> = bytes} = Codec.encode(verifying)
    raw = :erlang.binary_to_term(body)
    refute Map.has_key?(raw.exports[id], :native_authority)
    refute Map.has_key?(raw.exports[id].receipt, :native_publication)
    assert {:ok, ^verifying} = Codec.decode(bytes)

    for poisoned <- [
          put_in(raw.exports[id], Map.put(raw.exports[id], :native_authority, nil)),
          put_in(
            raw.exports[id].receipt,
            Map.put(raw.exports[id].receipt, :native_publication, nil)
          )
        ] do
      assert {:error, _} =
               Codec.decode("smolbox-record-v11\0" <> :erlang.term_to_binary(poisoned))
    end

    assert {:error, _} = Codec.encode(put_in(verifying.exports[id].receipt, receipt(proof)))
  end

  test "fresh BEAM loads v28 proof vocabulary before safe decoding" do
    record =
      NativeExportContract.lifecycle(
        Memory,
        start_supervised!(Memory)
      )

    assert {:ok, bytes} = Codec.encode(record)

    path =
      Path.join(
        System.tmp_dir!(),
        "smolbox-export-history-" <> Base.encode16(:crypto.strong_rand_bytes(16))
      )

    on_exit(fn -> File.rm(path) end)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin"))

    code = ~S"""
    [path] = System.argv()
    case path |> File.read!() |> SmolBox.Store.Codec.decode() do
      {:ok, %{exports: exports}} ->
        case Enum.any?(exports, fn {_, record} ->
          match?(%SmolBox.Embedded.ExportAuthority{cleanup: %SmolBox.Embedded.ExportStageCleanup{}}, record.native_authority)
        end) do
          true -> IO.puts("fresh-export")
          false -> System.halt(1)
        end
      _ -> System.halt(1)
    end
    """

    assert {"fresh-export\n", 0} =
             System.cmd(
               System.find_executable("elixir"),
               Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code, path],
               stderr_to_stdout: true
             )
  end
end
