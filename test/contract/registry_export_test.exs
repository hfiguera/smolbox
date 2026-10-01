defmodule SmolBox.RegistryExportTest do
  use ExUnit.Case, async: true
  alias SmolBox.{ExportPeer, ExportReceipt, ExportResult, ExportSpec, RegistryExport}

  setup do
    {registry, destination} = ExportPeer.start()
    {:ok, spec} = ExportSpec.new(id: "snapshot", tag: "snapshot", destination: destination)
    %{registry: registry, spec: spec, token: "export-test-token"}
  end

  test "verified publication pins three distinct identities and needs explicit source approval",
       context do
    assert :ok = RegistryExport.vacant(context.spec, "x86_64", context.token)
    receipt = publish(context)
    assert {:ok, result} = RegistryExport.verify(context.spec, receipt, context.token, 1000)

    assert MapSet.size(
             MapSet.new([result.manifest_sha256, result.config_sha256, result.content_sha256])
           ) == 3

    assert {:error, _} = ExportResult.source(result, [])
    assert {:ok, source} = ExportResult.source(result, id: "approved-copy")
    assert source.reference == result.reference
    assert source.sha256 == result.manifest_sha256
    assert source.content_sha256 == result.content_sha256

    assert {:error, %{category: :identity_conflict}} =
             RegistryExport.vacant(context.spec, "x86_64", context.token)
  end

  test "publication records the selected runtime while preserving legacy receipts", context do
    receipt = publish(context)

    for version <- ["1.19.0", "1.20.2", "1.22.0"] do
      assert {:ok, %{runtime_version: ^version} = result} =
               RegistryExport.verify(context.spec, receipt, context.token, 1000, version)

      assert :ok = ExportResult.validate(result)
    end

    assert {:error, _} =
             RegistryExport.verify(context.spec, receipt, context.token, 1000, "1.20.3")
  end

  test "authentication failure is not absence and does not expose a token", context do
    token = "unrecognized-secret"
    assert {:error, error} = RegistryExport.vacant(context.spec, "x86_64", token)
    refute error.category == :not_found
    refute inspect(error) =~ token
    receipt = publish(context)
    assert {:error, error} = RegistryExport.verify(context.spec, receipt, token, 1000)
    refute inspect(error) =~ token
  end

  for {label, suffix} <- [
        {"pinned manifest bytes", "manifests/sha256:"},
        {"config bytes", "blobs/"},
        {"platform tag", "manifests/snapshot-linux-amd64"},
        {"index tag", "manifests/snapshot"}
      ] do
    test "rejects corrupted #{label}", context do
      receipt = publish(context)
      suffix = unquote(suffix)

      Agent.update(context.registry, fn state ->
        objects =
          Map.new(state.objects, fn {path, {media, bytes}} ->
            corrupt = String.contains?(path, suffix)
            {path, {media, if(corrupt, do: bytes <> "corrupted", else: bytes)}}
          end)

        %{state | objects: objects}
      end)

      assert {:error, _} = RegistryExport.verify(context.spec, receipt, context.token, 1000)
    end
  end

  test "missing artifact blob cannot become a reusable result", context do
    receipt = publish(context)
    assert {:ok, verified} = RegistryExport.verify(context.spec, receipt, context.token, 1000)

    Agent.update(context.registry, fn state ->
      path = "/v2/team/exports/blobs/sha256:" <> verified.content_sha256
      %{state | objects: Map.delete(state.objects, path)}
    end)

    assert {:error, %{category: :not_found}} =
             RegistryExport.verify(context.spec, receipt, context.token, 1000)
  end

  test "receipt size and platform must agree with independently fetched descriptors", context do
    receipt = publish(context)

    assert {:error, _} =
             RegistryExport.verify(
               context.spec,
               %{receipt | size_bytes: receipt.size_bytes + 1},
               context.token,
               1000
             )

    assert {:error, _} =
             RegistryExport.verify(
               context.spec,
               %{receipt | platform: "linux/arm64"},
               context.token,
               1000
             )
  end

  defp publish(context) do
    wire =
      ExportPeer.publish(context.registry, %{
        "pushToken" => context.token,
        "repo" => context.spec.destination.repository,
        "tag" => context.spec.tag
      })

    {:ok, receipt} = ExportReceipt.from_wire(wire)
    receipt
  end
end
