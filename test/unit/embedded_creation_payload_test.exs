defmodule SmolBox.EmbeddedCreationPayloadTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{CreationPayload, JSON, Protocol}

  @fixture Path.expand(
             "../../native/smolbox-protocol/fixtures/compact-creation-request.json",
             __DIR__
           )

  test "shared compact fixture preserves UTF-8 control bytes and literal argv" do
    features = %{
      "network" => %{"enabled" => false, "hosts" => [], "cidrs" => []},
      "ports" => [%{"host" => 8080, "guest" => 80}],
      "workload" => %{
        "entrypoint" => ["/bin/app"],
        "cmd" => ["literal; $(text)", "é\x01"],
        "env" => %{"PRIVATE" => "opaque\x01value"},
        "workdir" => "/app"
      }
    }

    assert {:ok, payload} = CreationPayload.encode(features)
    fixture = Jason.decode!(File.read!(@fixture))
    assert fixture["operation"]["features_payload"] == payload
    assert {:ok, _frame} = JSON.encode(fixture)
  end

  test "maximally escaped valid workload fits without widening ordinary frame or file limits" do
    env =
      Map.new(1..64, fn index ->
        {"K#{index}" <> String.duplicate("X", 124), String.duplicate("\x01", 8192)}
      end)

    hosts =
      for index <- 1..32,
          do:
            Enum.join(
              List.duplicate(String.duplicate("a", 63), 3) ++
                [String.pad_leading("h#{index}", 61, "a")],
              "."
            )

    cidrs =
      for index <- 1..32,
          do:
            to_string(
              :inet.ntoa({0x2001, 0xDB8, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000 + index})
            ) <> "/128"

    features = %{
      "network" => %{"enabled" => true, "hosts" => Enum.sort(hosts), "cidrs" => Enum.sort(cidrs)},
      "ports" => Enum.map(1..32, &%{"host" => &1, "guest" => 80}),
      "workload" => %{
        "entrypoint" => [String.duplicate("\x01", 16_384)],
        "cmd" =>
          [
            String.duplicate("\x01", 16_384),
            String.duplicate("\x01", 16_384),
            String.duplicate("\x01", 16_380)
          ] ++ List.duplicate("", 251),
        "env" => env,
        "workdir" => "/" <> String.duplicate("a", 4095)
      }
    }

    assert :error = JSON.encode(features)
    assert {:ok, payload} = CreationPayload.encode(features)
    bytes = Enum.map(payload["chunks"], &Base.decode64!/1)
    assert IO.iodata_length(bytes) <= CreationPayload.limits()["payload_bytes"]
    assert Enum.all?(Enum.drop(bytes, -1), &(byte_size(&1) == 65_536))
    assert {:ok, encoded} = JSON.encode(%{"features_payload" => payload})
    assert byte_size(encoded) < 1_048_576
    assert Protocol.limits(2, 0)["frame_bytes"] == 1_048_576
    assert Protocol.limits(2, 0)["transfer_bytes"] == 16_777_216
    assert Protocol.limits(2, 0)["creation"] == CreationPayload.limits()
  end

  test "invalid workload values cannot become opaque unvalidated payloads" do
    for value <- [nil, %{}, %{"network" => false}, %{"ports" => []}] do
      assert :error = CreationPayload.encode(value)
    end
  end
end
