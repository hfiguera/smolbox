defmodule SmolBox.EmbeddedExportBackendTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{Budget, Embedded, EmbeddedContext, EmbeddedExport, HTTP}
  alias SmolBox.Embedded.{Config, ExportContract}
  alias SmolBox.Store.{ExportOps, NativeExportContract}

  defp fixture do
    {_, accepted, spec, request, proof} = NativeExportContract.fixture()

    {:ok, sent} =
      ExportOps.advance(
        accepted,
        spec.id,
        :accepted,
        [state: :dispatching, native_request: request],
        1101
      )

    context = %EmbeddedContext{
      config: struct(Config),
      server: self(),
      spec: sent.spec,
      export: sent.exports[spec.id]
    }

    operation = %{
      "operation" => "export_machine",
      "receipt" => proof.source,
      "operation_id" => proof.operation_id,
      "request" => request,
      "push_token" => "private-fixture-bearer"
    }

    wire =
      proof |> Map.from_struct() |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    {accepted, context, operation, wire}
  end

  defp empty, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  defp budget,
    do: %Budget{timeout_ms: 1000, max_request_bytes: 1_048_576, max_response_bytes: 16384}

  test "request construction shares exact approved scratch across source logical disks and artifact" do
    {accepted, _, _, _} = fixture()
    export = accepted.exports[accepted.active_export]
    [approval] = ExportContract.approvals(%{export_destinations: [export.spec.destination]})
    approval = Map.take(approval, ~w(id destination_sha256 max_artifact_bytes max_staging_bytes))
    resources = accepted.backend_assignment.creation["resources"]
    assert {:ok, request} = EmbeddedExport.build_request(export, approval, resources)
    assert request["max_artifact_bytes"] + 2 * 1_073_741_824 == request["max_staging_bytes"]
    assert request["request_sha256"] == export.fingerprint
    refute Jason.encode!(request) =~ "private-fixture-bearer"

    for invalid <- [
          Map.put(approval, "id", "foreign"),
          Map.put(approval, "max_staging_bytes", 1),
          Map.put(approval, "max_artifact_bytes", 0),
          Map.put(approval, "ca_cert_file", "/foreign.pem")
        ] do
      assert {:error, %{evidence: :not_dispatched}} =
               EmbeddedExport.build_request(export, invalid, resources)
    end
  end

  test "funded catalogs freeze upper bounds without guessing container or bare layout" do
    {accepted, _, _, _} = fixture()
    export = accepted.exports[accepted.active_export]
    [catalog] = ExportContract.approvals(%{export_destinations: [export.spec.destination]})

    approval =
      Map.take(
        catalog,
        ~w(id destination_sha256 max_artifact_bytes max_staging_bytes conversion_resources)
      )

    resources = accepted.backend_assignment.creation["resources"]
    assert {:ok, request} = EmbeddedExport.build_request(export, approval, resources)
    assert request["max_artifact_bytes"] == request["max_staging_bytes"] - 1
    assert request["request_sha256"] == export.fingerprint
    refute Map.has_key?(request, "conversion_resources")
    refute Map.has_key?(request, "source_mode")

    for invalid <- [
          Map.put(approval, "conversion_resources", nil),
          put_in(approval["conversion_resources"]["cpus"], 5),
          Map.put(approval, "source_mode", "container")
        ] do
      assert {:error, %{evidence: :not_dispatched}} =
               EmbeddedExport.build_request(export, invalid, resources)
    end

    legacy = Map.delete(approval, "conversion_resources")
    assert {:ok, old} = EmbeddedExport.build_request(export, legacy, resources)
    assert old["max_artifact_bytes"] + 2 * 1_073_741_824 == old["max_staging_bytes"]

    assert {:ok, dispatching} =
             ExportOps.advance(
               accepted,
               export.spec.id,
               :accepted,
               [state: :dispatching, native_request: request],
               1101
             )

    frozen = dispatching.exports[export.spec.id]
    assert frozen.native_authority.request == request
    assert :error = SmolBox.Embedded.ExportAuthority.freeze_request(frozen, old)
  end

  test "public receipt retains only exact acknowledged authority and rejects output or overlay" do
    {_, context, request, wire} = fixture()
    result = {:ok, %{"result" => "exported", "publication" => wire}, empty(), nil}
    assert {:ok, receipt} = EmbeddedExport.decode(context, :export_machine, request, result)
    assert receipt.native_publication.source == context.export.native_authority.source
    refute inspect(receipt) =~ "private-fixture-bearer"

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :export_machine,
               put_in(request["request"]["tag"], "foreign"),
               result
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :export_machine,
               request,
               {:ok, elem(result, 1), %{empty() | stdout: "unexpected"}, nil}
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :export_machine,
               request,
               {:ok, elem(result, 1), empty(),
                %SmolBox.Error{category: :output_limit, operation: :export}}
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               %{
                 context
                 | spec: %{
                     context.spec
                     | artifact: Map.put(context.spec.artifact, "architecture", "aarch64")
                   }
               },
               :export_machine,
               request,
               result
             )
  end

  test "admission acknowledgement is zero-output and cannot become an export receipt" do
    {_, context, request, wire} = fixture()
    request = request |> Map.delete("push_token") |> Map.put("operation", "admit_export")
    result = {:ok, %{"result" => "qualified"}, empty(), nil}
    assert :ok = EmbeddedExport.decode(context, :admit_export, request, result)

    assert {:error, _} =
             EmbeddedExport.decode(context, :export_machine, request, result)

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :admit_export,
               request,
               {:ok, %{"result" => "exported", "publication" => wire}, empty(), nil}
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :admit_export,
               request,
               {:ok, %{"result" => "qualified"}, %{empty() | file: "unexpected"}, nil}
             )
  end

  test "lookup conveys no absence or replay authority and cleanup remains distinct" do
    {_, context, _, wire} = fixture()
    request = EmbeddedExport.control(context.export, "inspect_export")

    assert {:ok, proof} =
             EmbeddedExport.decode(
               context,
               :inspect_export,
               request,
               {:ok, %{"result" => "export_presence", "publication" => wire}, empty(), nil}
             )

    assert proof.operation_id == context.export.spec.id

    assert {:ok, nil} =
             EmbeddedExport.decode(
               context,
               :inspect_export,
               request,
               {:ok, %{"result" => "export_presence", "publication" => nil}, empty(), nil}
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :inspect_export,
               request,
               {:ok, %{"result" => "exported", "publication" => wire}, empty(), nil}
             )

    cleanup =
      "../../native/smolbox-protocol/fixtures/export-cleanups-v1.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> hd()

    request =
      EmbeddedExport.control(context.export, "cleanup_export_staging")
      |> Map.put("quiesced", true)

    assert {:ok, _} =
             EmbeddedExport.decode(
               context,
               :cleanup_export,
               request,
               {:ok, %{"result" => "export_staging_cleaned", "cleanup" => cleanup}, empty(), nil}
             )

    assert {:error, _} =
             EmbeddedExport.decode(
               context,
               :cleanup_export,
               request,
               {:ok, %{"result" => "export_staging_cleaned", "cleanup" => wire}, empty(), nil}
             )
  end

  test "currently approved descriptors reject managed export controls before dispatch" do
    {_, context, request, _} = fixture()

    for operation <- [:export_machine, :qualify_export, :inspect_export, :cleanup_export] do
      assert Embedded.supports_operation?(nil, operation)
      refute Embedded.supports_operation?(context, operation)
    end

    refute HTTP.supports_operation?(nil, :cleanup_export)

    assert {:error, %{evidence: :not_dispatched}} =
             EmbeddedExport.run(
               context,
               [context.name, context.export.spec, request["push_token"]],
               budget()
             )

    assert {:error, _} = EmbeddedExport.qualify(context, budget())
    assert {:error, _} = EmbeddedExport.lookup(context, budget())
    assert {:error, _} = EmbeddedExport.cleanup(context, context.export, budget())

    assert {:error, %{operation: :export, evidence: :not_dispatched}} =
             EmbeddedExport.decode(
               context,
               :export_machine,
               request,
               {:ok,
                %{"result" => "error", "code" => "unsupported", "dispatch" => "not_dispatched"},
                empty(), nil}
             )
  end
end
