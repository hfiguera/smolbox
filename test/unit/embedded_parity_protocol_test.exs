defmodule SmolBox.Embedded.ParityProtocolTest do
  use ExUnit.Case, async: true

  alias SmolBox.Embedded.{
    Channel,
    JSON,
    Limits,
    MaterialProof,
    Protocol,
    Request,
    SDKIdentity,
    Shape
  }

  @fixtures Path.expand("../../native/smolbox-protocol/fixtures", __DIR__)
  defp body(name), do: @fixtures |> Path.join(name) |> File.read!()
  defp fixture(name), do: body(name) |> Jason.decode!()

  test "shared native fixtures have strict major-2 SDK and material shapes" do
    assert {:ok, %{"hello" => hello}} = Protocol.decode(body("hello-v2.json"), 2)
    assert :error = Protocol.decode(body("hello-v2.json"))
    assert hello["major"] == 2 and hello["minor"] == 0
    assert hello["sdk"]["sdk_version"] == "1.22.0"
    assert SDKIdentity.valid?(hello["sdk"])
    assert {:ok, terminal} = Protocol.decode(body("created-v2.json"), 2)
    assert :error = Protocol.decode(body("created-v2.json"), 1)
    receipt = terminal["outcome"]["receipt"]
    assert Shape.receipt?(receipt, 2)
    refute Shape.receipt?(receipt)
    assert MaterialProof.valid?(receipt["material"])
    request = fixture("inspect-v2-request.json")
    assert Request.valid?(request["operation"], request["budget_ms"], 2)
    refute Request.valid?(request["operation"], request["budget_ms"])
    stripped = update_in(request, ["operation", "receipt"], &Map.delete(&1, "material"))
    refute Request.valid?(stripped["operation"], 1000, 2)
  end

  test "volume negotiation binds exact limits Linux and dependencies without activation" do
    message = fixture("hello-v2-volumes.json")
    hello = message["hello"]
    assert {:ok, _} = Protocol.decode(Jason.encode!(message), 2)
    assert hello["limits"] == Protocol.limits(2, 0, hello["sdk"])
    assert hello["capabilities"] == Protocol.capabilities(hello["sdk"])
    assert hello["limits"]["volumes"]["control_metadata_bytes"] == 262_144
    assert hello["limits"]["jobs"]["metadata_bytes"] == 33_554_432
    refute SDKIdentity.approved?(hello["sdk"], "1.22.0", hello["package"]["smolvm_revision"])

    for key <- Map.keys(hello["limits"]["volumes"]) do
      altered = put_in(message, ["hello", "limits", "volumes", key], 0)
      assert :error = Protocol.decode(Jason.encode!(altered), 2)
    end

    assert :error =
             Protocol.decode(
               Jason.encode!(update_in(message, ["hello", "limits"], &Map.delete(&1, "volumes"))),
               2
             )

    assert :error =
             Protocol.decode(
               Jason.encode!(put_in(message, ["hello", "package", "platform"], "macos")),
               2
             )

    for dependency <- ~w(job_resources buffered_exec compact_creation) do
      sdk = update_in(hello["sdk"], ["feature_versions"], &Map.delete(&1, dependency))
      refute SDKIdentity.valid?(sdk)
    end

    refute Map.has_key?(Protocol.limits(1, 4), "volumes")
    refute Map.has_key?(fixture("hello-v2-current.json")["hello"]["limits"], "volumes")
  end

  test "SDK approval is explicit and binds the complete feature and source identity" do
    hello = fixture("hello-v2.json")["hello"]

    config = %{
      id: hello["domain"]["target_id"],
      domain_generation: hello["domain"]["generation"],
      package_identity: hello["package"],
      limits: %Limits{}
    }

    assert Protocol.approve(hello, config, hello["sdk"])
    refute Protocol.approve(hello, config)
    wrong = put_in(hello, ["sdk", "feature_versions", "networking"], 1)
    refute Protocol.approve(wrong, config, hello["sdk"])

    for sdk <- [
          Map.put(hello["sdk"], "source_revision", String.duplicate("0", 40)),
          Map.put(hello["sdk"], "unknown", true),
          put_in(hello["sdk"], ["feature_versions", "networking"], 2),
          put_in(hello["sdk"], ["feature_versions", "unknown"], 1),
          update_in(hello["sdk"], ["feature_versions"], &Map.delete(&1, "material_proofs"))
        ] do
      modified = Map.put(hello, "sdk", sdk)
      refute Protocol.approve(modified, config, hello["sdk"])
    end
  end

  test "malformed package and SDK fields fail closed without decoder exceptions" do
    valid = fixture("hello-v2.json")

    for invalid <- [nil, false, 123, [], "invalid", %{}] do
      for field <- ["sdk", "package", "domain"] do
        modified = put_in(valid, ["hello", field], invalid)
        assert :error = Protocol.decode(Jason.encode!(modified), 2)
      end
    end

    assert :error = Protocol.decode(body("created-v2.json"), 99)
    refute Protocol.valid_outcome?(fixture("created-v2.json")["outcome"], 99)
  end

  test "material validation rejects unknown fields inconsistent roots and incomplete transitions" do
    receipt = fixture("created-v2.json")["outcome"]["receipt"]

    for {field, value} <- [
          {"schema", 1},
          {"revision", 1025},
          {"record_sha256", String.duplicate("0", 64)},
          {"operation_id", "unexpected-root-operation"},
          {"request_sha256", String.duplicate("a", 64)},
          {"unknown", true}
        ] do
      invalid = put_in(receipt, ["material", field], value)
      refute Shape.receipt?(invalid, 2)
    end

    advanced = put_in(receipt, ["material", "revision"], 1)
    refute Shape.receipt?(advanced, 2)

    advanced =
      advanced
      |> put_in(["material", "operation_id"], "grow-1")
      |> put_in(["material", "request_sha256"], String.duplicate("a", 64))
      |> put_in(["material", "record_sha256"], String.duplicate("0", 64))

    assert Shape.receipt?(advanced, 2)
    refute Shape.receipt?(Map.put(advanced, "unknown", true), 2)
  end

  test "major-2 channel retains correlation and sticky unavailability without downgrading proof" do
    hello = fixture("hello-v2.json")["hello"]
    operation = fixture("inspect-v2-request.json")["operation"]
    channel = Channel.new(hello)
    assert {:ok, 1, channel} = Channel.register(channel, operation, 10, 2)
    unavailable = %{"type" => "unavailable", "epoch" => hello["epoch"]}
    assert {:ok, closed, :unavailable} = Channel.receive_message(channel, unavailable)
    assert closed.unavailable
    assert map_size(closed.pending) == 1
    assert :error = Channel.register(closed, operation, 10, 2)
    legacy_channel = %{channel | major: 1, minor: 4, pending: %{}, last_id: 0}
    assert :error = Channel.register(legacy_channel, operation, 10, 2)
    assert :error = Channel.receive_message(channel, Map.put(unavailable, "epoch", "00"))
  end

  test "the existing negative command fixture remains valid on the legacy path" do
    assert {:ok, request} = JSON.decode(body("exec-request.json"))
    assert Request.valid?(request["operation"], request["budget_ms"])
    refute Request.valid?(request["operation"], request["budget_ms"], 2)
    assert {:ok, _terminal} = Protocol.decode(body("exec-terminal.json"))
  end
end
