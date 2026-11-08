defmodule SmolBox.EmbeddedImagesWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{EmbeddedContext, EmbeddedReply}
  alias SmolBox.Embedded.{Channel, Identity, Protocol, Request, SDKIdentity}
  alias SmolBox.{Error, ImageInventory}

  defp receipt do
    "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> hd()
    |> Map.fetch!("previous")
  end

  defp request, do: %{"operation" => "list_images", "receipt" => receipt()}

  defp context,
    do: %EmbeddedContext{config: nil, server: self(), identity: %Identity{receipt: receipt()}}

  defp images do
    "../../native/smolbox-protocol/fixtures/image-inventory-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
  end

  defp result(images) do
    bytes = Jason.encode!(images)
    outcome = %{"result" => "images", "count" => length(images), "bytes" => byte_size(bytes)}
    {:ok, outcome, %{stdout: <<>>, stderr: <<>>, file: bytes}, nil}
  end

  test "listing is scoped, versioned and uses a finite work budget" do
    assert Request.valid?(request(), 30_000, 2)
    refute Request.valid?(request(), 30_001, 2)
    refute Request.valid?(request(), 1000, 1)
    refute Request.valid?(Map.delete(request(), "receipt"), 1000, 2)
    refute Request.valid?(Map.put(request(), "extra", true), 1000, 2)
    refute Request.observation?(request())
  end

  test "typed results preserve packed and configuration observations and empty uncertainty" do
    assert {:ok, %ImageInventory{availability: :observed, images: [packed, config]}} =
             EmbeddedReply.decode(context(), :list_images, request(), result(images()))

    assert packed.digest_kind == :packed
    assert config.digest_kind == :configuration
    assert config.digest != String.replace(config.reference, "fixture/repository@", "")

    assert {:ok, %ImageInventory{availability: :empty_or_unavailable, images: []}} =
             EmbeddedReply.decode(context(), :list_images, request(), result([]))
  end

  test "typed decoding rejects crossed receipts, corrupt projections and mismatched counts" do
    {:ok, outcome, output, nil} = result(images())

    for {request, outcome, output} <- [
          {put_in(request()["receipt"]["name"], "foreign"), outcome, output},
          {request(), Map.put(outcome, "count", 1), output},
          {request(), Map.put(outcome, "bytes", 2), output},
          {request(), outcome, %{output | stdout: "extra"}},
          {request(), outcome, %{output | file: "malformed"}}
        ] do
      assert {:error, %Error{operation: :images}} =
               EmbeddedReply.decode(context(), :list_images, request, {:ok, outcome, output, nil})
    end

    invalid = put_in(images(), [Access.at(0), "digest"], "not-a-digest")

    assert {:error, %Error{operation: :images}} =
             EmbeddedReply.decode(context(), :list_images, request(), result(invalid))
  end

  test "channel binds file byte totals and rejects crossed inventory outcomes" do
    r = receipt()

    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("ab", 16),
        "domain" => %{"target_id" => r["target_id"], "generation" => r["domain_generation"]}
      })

    assert {:ok, 1, channel} = Channel.register(channel, request(), 262_144, 64)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, message(channel, 0, %{"type" => "accepted"}))

    assert :error = Channel.receive_message(channel, event(channel, 1, "stdout", "[]"))

    terminal = %{
      "type" => "terminal",
      "outcome" => %{"result" => "images", "count" => 0, "bytes" => 2}
    }

    assert :error = Channel.receive_message(channel, message(channel, 1, terminal))
    assert {:ok, channel, _} = Channel.receive_message(channel, event(channel, 1, "file", "["))
    assert {:ok, channel, _} = Channel.receive_message(channel, event(channel, 2, "file", "]"))

    assert :error =
             Channel.receive_message(
               channel,
               message(channel, 3, put_in(terminal, ["outcome", "result"], "inventory"))
             )

    assert {:ok, retired, _} = Channel.receive_message(channel, message(channel, 3, terminal))
    assert :error = Channel.receive_message(retired, message(retired, 3, terminal))
    refute Protocol.valid_outcome?(terminal["outcome"], 1)
    refute Protocol.valid_outcome?(put_in(terminal["outcome"]["count"], 1025), 2)
  end

  test "large inventories cross the initial window through bounded acknowledged chunks" do
    entry = hd(images()) |> Map.put("reference", String.duplicate("r", 1024))
    entries = List.duplicate(entry, 1024)
    {:ok, outcome, output, nil} = result(entries)
    assert byte_size(output.file) > 262_144

    assert {:ok, %ImageInventory{images: decoded}} =
             EmbeddedReply.decode(context(), :list_images, request(), result(entries))

    assert Enum.count_until(decoded, 1025) == 1024

    assert {:error, %Error{operation: :images}} =
             EmbeddedReply.decode(context(), :list_images, request(), result([entry | entries]))

    r = receipt()

    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("ab", 16),
        "domain" => %{"target_id" => r["target_id"], "generation" => r["domain_generation"]}
      })

    assert {:ok, 1, channel} = Channel.register(channel, request(), 65_536, 1)

    assert {:ok, channel, _} =
             Channel.receive_message(channel, message(channel, 0, %{"type" => "accepted"}))

    chunks =
      Stream.unfold(output.file, fn
        <<>> ->
          nil

        bytes ->
          size = min(byte_size(bytes), 65_536)
          {binary_part(bytes, 0, size), binary_part(bytes, size, byte_size(bytes) - size)}
      end)

    {channel, next} =
      Enum.reduce(chunks, {channel, 1}, fn chunk, {channel, sequence} ->
        assert {:ok, channel, _} =
                 Channel.receive_message(channel, event(channel, sequence, "file", chunk))

        assert {:ok, channel, %{events: 1, native_credit: true}} =
                 Channel.acknowledge(channel, 1, byte_size(chunk))

        assert channel.queued_bytes == 0
        {channel, sequence + 1}
      end)

    assert {:ok, _, _} =
             Channel.receive_message(
               channel,
               message(channel, next, %{"type" => "terminal", "outcome" => outcome})
             )
  end

  test "planned image capability cannot be approved as an implemented package feature" do
    hello =
      "../../native/smolbox-protocol/fixtures/hello-v2-current.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("hello")

    sdk = put_in(hello["sdk"], ["feature_versions", "images"], 1)
    assert SDKIdentity.valid?(sdk)
    assert hd(Protocol.capabilities(sdk)) == "list_images"
    refute SDKIdentity.approved?(sdk, sdk["sdk_version"], sdk["source_revision"])
    refute "list_images" in Protocol.capabilities(hello["sdk"])

    refute SDKIdentity.valid?(
             update_in(sdk["feature_versions"], &Map.delete(&1, "job_resources"))
           )
  end

  defp message(channel, sequence, body),
    do: Map.merge(body, %{"epoch" => channel.epoch, "id" => 1, "sequence" => sequence})

  defp event(channel, sequence, stream, bytes),
    do:
      message(channel, sequence, %{
        "type" => "event",
        "event" => %{"stream" => stream, "data_base64" => Base.encode64(bytes)}
      })
end
