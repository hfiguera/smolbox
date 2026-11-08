defmodule SmolBox.EmbeddedPullWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Backend.{EmbeddedContext, EmbeddedReply}
  alias SmolBox.Embedded.{Channel, Identity, ImageContract, Protocol, Request}
  alias SmolBox.{Error, Image, ImagePull, Source}

  defp receipt do
    "../../native/smolbox-protocol/fixtures/growth-transitions-v1.json"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> hd()
    |> Map.fetch!("previous")
  end

  defp source do
    {:ok, source} =
      Source.oci(
        id: "approved-pull",
        reference: "registry.example/app@sha256:" <> String.duplicate("a", 64),
        architecture: "aarch64"
      )

    source
  end

  defp request,
    do: %{
      "operation" => "pull_image",
      "receipt" => receipt(),
      "source" => ImageContract.source(source())
    }

  defp outcome do
    %{
      "result" => "pulled",
      "image" => %{
        "reference" => source().reference,
        "digest" => "sha256:" <> String.duplicate("b", 64),
        "size" => 123,
        "architecture" => "arm64",
        "os" => "linux",
        "layerCount" => 2
      }
    }
  end

  defp context do
    %EmbeddedContext{
      config: nil,
      server: self(),
      identity: %Identity{receipt: receipt()},
      spec: %{command: %ImagePull{source: source()}}
    }
  end

  defp output, do: %{stdout: <<>>, stderr: <<>>, file: <<>>}

  test "pull request is versioned, pinned and cannot contain authentication or proxy overrides" do
    assert Request.valid?(request(), 86_400_000, 2)
    refute Request.valid?(request(), 86_400_001, 2)
    refute Request.valid?(request(), 1000, 1)
    refute Request.observation?(request())

    for invalid <- [
          Map.put(request()["source"], "auth", "PRIVATE=discard"),
          Map.put(request()["source"], "proxy", "https://example.com"),
          Map.put(request()["source"], "reference", "registry.example/app:tag"),
          Map.put(request()["source"], "platform", "linux/invalid")
        ] do
      refute Request.valid?(Map.put(request(), "source", invalid), 1000, 2)
    end
  end

  test "pulled evidence returns the existing configuration digest type, not manifest or process evidence" do
    assert Protocol.valid_outcome?(outcome(), 2)
    refute Protocol.valid_outcome?(outcome(), 1)

    assert {:ok, %Image{digest_kind: :configuration, digest: digest}} =
             EmbeddedReply.decode(
               context(),
               :pull_image,
               request(),
               {:ok, outcome(), output(), nil}
             )

    assert digest == "sha256:" <> String.duplicate("b", 64)
    refute digest == "sha256:" <> String.duplicate("a", 64)
    refute Protocol.valid_outcome?(put_in(outcome()["image"]["digest"], "packed"), 2)
  end

  test "reply rejects crossed source intent, reference, platform, receipt and output" do
    for {request, outcome, output} <- [
          {put_in(
             request()["source"]["reference"],
             "registry.example/other@sha256:" <> String.duplicate("a", 64)
           ), outcome(), output()},
          {request(), put_in(outcome()["image"]["reference"], "different"), output()},
          {request(), put_in(outcome()["image"]["architecture"], "amd64"), output()},
          {put_in(request()["receipt"]["name"], "foreign"), outcome(), output()},
          {request(), outcome(), %{output() | file: "extra"}}
        ] do
      assert {:error, %Error{operation: :pull_image}} =
               EmbeddedReply.decode(context(), :pull_image, request, {:ok, outcome, output, nil})
    end
  end

  test "channel accepts only matching pulled completion with no event stream" do
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

    assert :error =
             Channel.receive_message(
               channel,
               message(channel, 1, %{
                 "type" => "event",
                 "event" => %{"stream" => "file", "data_base64" => Base.encode64("[]")}
               })
             )

    assert :error =
             Channel.receive_message(
               channel,
               message(channel, 1, %{
                 "type" => "terminal",
                 "outcome" => %{"result" => "images", "count" => 0, "bytes" => 2}
               })
             )

    assert :error =
             Channel.receive_message(
               channel,
               message(channel, 1, %{
                 "type" => "terminal",
                 "outcome" => put_in(outcome()["image"]["reference"], "different")
               })
             )

    assert {:ok, retired, _} =
             Channel.receive_message(
               channel,
               message(channel, 1, %{"type" => "terminal", "outcome" => outcome()})
             )

    assert :error =
             Channel.receive_message(
               retired,
               message(retired, 1, %{"type" => "terminal", "outcome" => outcome()})
             )
  end

  defp message(channel, sequence, body),
    do: Map.merge(body, %{"epoch" => channel.epoch, "id" => 1, "sequence" => sequence})
end
