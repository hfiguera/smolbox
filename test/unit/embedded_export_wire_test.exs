defmodule SmolBox.Embedded.ExportWireTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    Channel,
    ExportContract,
    ExportPublication,
    ExportStageCleanup,
    Protocol,
    RegistryContract,
    Request,
    SDKIdentity
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp proof, do: hd(fixture("export-publications-v1.json"))
  defp cleanup, do: hd(fixture("export-cleanups-v1.json"))

  defp request(proof),
    do: %{
      "request_sha256" => proof["request_sha256"],
      "destination_id" => proof["identity"]["destination_id"],
      "destination_sha256" => proof["identity"]["destination_sha256"],
      "tag" => proof["identity"]["tag"],
      "max_artifact_bytes" => 1_048_576,
      "max_staging_bytes" => 4_194_304
    }

  defp operation(proof),
    do: %{
      "operation" => "export_machine",
      "receipt" => proof["source"],
      "operation_id" => proof["operation_id"],
      "request" => request(proof),
      "push_token" => "private-fixture-token"
    }

  defp channel(operation) do
    hello =
      fixture("hello-v2.json")["hello"]
      |> Map.put("domain", %{
        "target_id" => operation["receipt"]["target_id"],
        "generation" => operation["receipt"]["domain_generation"]
      })
      |> put_in(["package", "architecture"], "x86_64")

    assert {:ok, 1, channel} = Channel.register(Channel.new(hello), operation, 0, 0)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, %{
               "type" => "accepted",
               "epoch" => hello["epoch"],
               "id" => 1,
               "sequence" => 0
             })

    {hello, channel}
  end

  defp terminal(hello, outcome),
    do: %{
      "type" => "terminal",
      "epoch" => hello["epoch"],
      "id" => 1,
      "sequence" => 1,
      "outcome" => outcome
    }

  test "native publication fixture has exact canonical proof and remains distinct from cleanup" do
    wire = proof()
    assert {:ok, proof} = ExportPublication.from_wire(wire)

    assert ExportPublication.bound_request?(
             proof,
             wire["source"],
             wire["operation_id"],
             request(wire)
           )

    refute inspect(proof) =~ wire["source"]["owner_token"]
    assert :error = ExportStageCleanup.from_wire(wire)
    assert {:ok, cleanup} = ExportStageCleanup.from_wire(cleanup())
    refute inspect(cleanup) =~ wire["source"]["owner_token"]

    for field <- Map.keys(wire),
        do: assert(:error == ExportPublication.from_wire(Map.delete(wire, field)))

    for field <- ~w(destination_id tag content_sha256 config_sha256 manifest_sha256 index_sha256),
        do:
          assert(
            :error == ExportPublication.from_wire(put_in(wire, ["identity", field], "changed"))
          )

    assert :error = ExportPublication.from_wire(Map.put(wire, "metadata", %{}))
    assert :error = ExportPublication.from_wire(put_in(wire, ["source", "material"], nil))
    refute ExportPublication.bound?(proof, wire["source"], "foreign", wire["request_sha256"])

    refute ExportPublication.bound_request?(
             proof,
             wire["source"],
             wire["operation_id"],
             Map.put(request(wire), "max_artifact_bytes", 1)
           )
  end

  test "export request is path-free bounded and requires an explicit transient bearer" do
    operation = operation(proof())
    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    refute Request.valid?(Map.delete(operation, "push_token"), 1000, 2)
    refute Request.valid?(Map.put(operation, "path", "/operator/not-a-request-path"), 1000, 2)
    refute Request.valid?(put_in(operation, ["request", "destination_id"], "../foreign"), 1000, 2)

    refute Request.valid?(
             put_in(operation, ["request", "max_artifact_bytes"], 4_194_304),
             1000,
             2
           )

    refute Request.valid?(put_in(operation, ["request", "tag"], "../tag"), 1000, 2)
    sanitized = RegistryContract.sanitize(operation)
    refute Jason.encode!(sanitized) =~ "private-fixture-token"
    refute Request.valid?(sanitized, 1000, 2)
    {_hello, channel} = channel(operation)
    refute :erlang.term_to_binary(channel) =~ "private-fixture-token"
  end

  test "export terminal correlates request and platform and cannot claim cleanup or output" do
    wire = proof()
    operation = operation(wire)
    {hello, channel} = channel(operation)
    outcome = %{"result" => "exported", "publication" => wire}
    assert Protocol.valid_outcome?(outcome, 2)
    refute Protocol.valid_outcome?(outcome, 1)
    assert {:ok, _, _} = Channel.receive_message(channel, terminal(hello, outcome))

    assert :error =
             Channel.receive_message(
               channel,
               terminal(hello, %{"result" => "export_staging_cleaned", "cleanup" => cleanup()})
             )

    assert :error =
             Channel.receive_message(
               %{channel | pending: put_in(channel.pending, [1, :output_bytes], 1)},
               terminal(hello, outcome)
             )

    altered = put_in(channel.pending, [1, :operation, "request", "tag"], "foreign")

    assert :error =
             Channel.receive_message(%{channel | pending: altered}, terminal(hello, outcome))

    altered = put_in(channel.pending, [1, :export_platform], "linux/arm64")

    assert :error =
             Channel.receive_message(%{channel | pending: altered}, terminal(hello, outcome))
  end

  test "admission binds the frozen request without credentials or publication authority" do
    wire = proof()

    admission =
      operation(wire) |> Map.delete("push_token") |> Map.put("operation", "admit_export")

    assert Request.valid?(admission, 30_000, 2)
    refute Request.valid?(admission, 30_001, 2)
    refute Request.valid?(admission, 1000, 1)
    refute Request.valid?(Map.delete(admission, "operation_id"), 1000, 2)
    refute Request.valid?(Map.put(admission, "push_token", "private-fixture-token"), 1000, 2)
    refute Request.valid?(put_in(admission, ["receipt", "material"], nil), 1000, 2)
    refute Request.control?(admission)
    refute Request.reconciliation?(admission)
    {hello, channel} = channel(admission)

    assert {:ok, _, _} =
             Channel.receive_message(channel, terminal(hello, %{"result" => "qualified"}))

    assert :error =
             Channel.receive_message(
               channel,
               terminal(hello, %{"result" => "exported", "publication" => wire})
             )

    assert :error =
             Channel.receive_message(
               %{channel | pending: put_in(channel.pending, [1, :output_bytes], 1)},
               terminal(hello, %{"result" => "qualified"})
             )
  end

  test "lookup and cleanup use distinct zero-output control results while quarantined" do
    wire = proof()

    inspect = %{
      "operation" => "inspect_export",
      "receipt" => wire["source"],
      "operation_id" => wire["operation_id"],
      "request_sha256" => wire["request_sha256"]
    }

    cleanup_request =
      inspect |> Map.put("operation", "cleanup_export_staging") |> Map.put("quiesced", true)

    for request <- [inspect, cleanup_request] do
      assert Request.valid?(request, 30_000, 2)
      refute Request.valid?(request, 30_001, 2)
      assert Request.control?(request)
      assert Request.reconciliation?(request)
      {hello, channel} = channel(request)

      assert {:ok, quarantined, :unavailable} =
               Channel.receive_message(channel, %{
                 "type" => "unavailable",
                 "epoch" => hello["epoch"]
               })

      assert {:ok, 2, _channel} = Channel.register(quarantined, request, 0, 0)

      outcome =
        if request == inspect,
          do: %{"result" => "export_presence", "publication" => wire},
          else: %{"result" => "export_staging_cleaned", "cleanup" => cleanup()}

      assert {:ok, _, _} = Channel.receive_message(channel, terminal(hello, outcome))
      refute Protocol.valid_outcome?(%{"result" => "export_presence"}, 2)
    end

    refute Request.control?(%{cleanup_request | "quiesced" => false})
    {hello, channel} = channel(inspect)

    assert {:ok, _, _} =
             Channel.receive_message(
               channel,
               terminal(hello, %{"result" => "export_presence", "publication" => nil})
             )
  end

  test "operator approval hashes match native destination and approval checks perform no file reads" do
    {:ok, destination} =
      SmolBox.ExportDestination.new(
        id: "fixture-registry",
        registry: "registry.example",
        repository: "team/artifact",
        credential_ref: "publisher",
        immutable_tags: true,
        resources: %{slots: 1, cpus: 4, memory_mb: 4608, disk_gb: 128}
      )

    [approval] = ExportContract.approvals(%{export_destinations: [destination]})

    assert approval["conversion_resources"] == %{
             "slots" => 1,
             "cpus" => 4,
             "memory_mb" => 4608,
             "disk_gb" => 128
           }

    assert approval["destination_sha256"] == proof()["identity"]["destination_sha256"]
    assert ExportContract.approved_cached?([approval], operation(proof()))
    refute ExportContract.approved_cached?([], operation(proof()))

    refute ExportContract.approved_cached?(
             [approval],
             put_in(
               operation(proof()),
               ["request", "destination_sha256"],
               String.duplicate("0", 64)
             )
           )

    assert approval["ca_cert_file"] == nil
    refute Jason.encode!(approval) =~ "private-fixture-token"

    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    path = Path.join(System.tmp_dir!(), "smolbox-export-approval-" <> suffix <> ".pem")
    bytes = "fixture CA bytes"
    File.write!(path, bytes, [:exclusive])
    on_exit(fn -> File.rm(path) end)
    catalog = %{export_destinations: [%{destination | ca_cert_file: path}]}
    [with_ca] = ExportContract.approvals(catalog)

    assert with_ca["ca_cert_file"] == path

    assert with_ca["ca_certificate_sha256"] ==
             Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    refute with_ca["destination_sha256"] == approval["destination_sha256"]

    operation =
      put_in(operation(proof()), ["request", "destination_sha256"], with_ca["destination_sha256"])

    File.write!(path, <<>>)
    assert ExportContract.approved_cached?([with_ca], operation)

    assert_raise ArgumentError, "invalid export trust input", fn ->
      ExportContract.approvals(catalog)
    end
  end

  test "export bounds negotiate only with future capability and current public admission remains closed" do
    plain = %{"feature_versions" => %{}}
    refute Map.has_key?(Protocol.limits(2, 0, plain), "exports")

    sdk = %{
      "sdk_version" => "1.22.0",
      "source_revision" => String.duplicate("a", 40),
      "feature_versions" => %{"material_proofs" => 2, "exports" => 1}
    }

    refute SDKIdentity.valid?(sdk)

    sdk =
      update_in(
        sdk,
        ["feature_versions"],
        &Map.merge(&1, %{"job_resources" => 1, "buffered_exec" => 1, "compact_creation" => 1})
      )

    assert SDKIdentity.valid?(sdk)
    refute SDKIdentity.approved?(sdk, "1.22.0", sdk["source_revision"])
    assert Protocol.limits(2, 0, sdk)["exports"] == ExportContract.limits()
  end
end
