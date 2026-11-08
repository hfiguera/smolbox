defmodule SmolBox.EmbeddedRegistryWireTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Protocol, RegistryContract, Request}

  defp source do
    %{
      "reference" => "registry.example/team/app@sha256:" <> String.duplicate("a", 64),
      "platform" => "linux/arm64",
      "content_sha256" => String.duplicate("b", 64)
    }
  end

  test "registry preparation source and result are exact credential-free shapes" do
    request = %{"operation" => "prepare_artifact", "source" => source()}
    assert Request.valid?(request, 1000, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.valid?(Map.put(request, "identity_token", "private"), 1000, 2)
    assert RegistryContract.source?(source())

    result = %{
      "result" => "prepared_artifact",
      "source" => source(),
      "size_bytes" => 123,
      "already_cached" => false
    }

    assert Protocol.valid_outcome?(result, 2)
    refute Protocol.valid_outcome?(result, 1)

    for changed <- [
          Map.put(source(), "identity_token", "private"),
          Map.put(source(), "platform", "linux/riscv64"),
          Map.put(source(), "content_sha256", "bad")
        ] do
      refute RegistryContract.source?(changed)
      refute Protocol.valid_outcome?(%{result | "source" => changed}, 2)
    end

    refute Protocol.valid_outcome?(%{result | "size_bytes" => 0}, 2)
    refute Protocol.valid_outcome?(Map.put(result, "path", "/private/cache"), 2)
  end

  test "preparation terminal correlates source and accepts no output events" do
    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("ab", 16),
        "domain" => %{"target_id" => "test", "generation" => String.duplicate("cd", 16)}
      })

    {:ok, 1, channel} =
      Channel.register(
        channel,
        %{"operation" => "prepare_artifact", "source" => source()},
        262_144,
        64
      )

    base = %{"epoch" => channel.epoch, "id" => 1}

    {:ok, channel, _} =
      Channel.receive_message(channel, Map.merge(base, %{"type" => "accepted", "sequence" => 0}))

    result = %{
      "result" => "prepared_artifact",
      "source" => source(),
      "size_bytes" => 123,
      "already_cached" => true
    }

    crossed = %{
      result
      | "source" => Map.put(source(), "content_sha256", String.duplicate("c", 64))
    }

    assert :error ==
             Channel.receive_message(
               channel,
               Map.merge(base, %{"type" => "terminal", "sequence" => 1, "outcome" => crossed})
             )

    assert :error ==
             Channel.receive_message(
               channel,
               Map.merge(base, %{
                 "type" => "event",
                 "sequence" => 1,
                 "stream" => "file",
                 "data" => Base.encode64("private")
               })
             )

    assert {:ok, _, _} =
             Channel.receive_message(
               channel,
               Map.merge(base, %{"type" => "terminal", "sequence" => 1, "outcome" => result})
             )
  end

  test "preparation capability remains conditional on the future descriptor" do
    refute "prepare_artifact" in Protocol.capabilities(%{"feature_versions" => %{}})

    assert Protocol.capabilities(%{"feature_versions" => %{"remote_sources" => 1}}) |> hd() ==
             "prepare_artifact"
  end

  test "registry creation and absence preserve durable identity and reject OCI substitution" do
    source = %{
      "kind" => "registry",
      "id" => "approved",
      "sha256" => String.duplicate("a", 64),
      "architecture" => "aarch64",
      "reference" => source()["reference"],
      "content_sha256" => String.duplicate("b", 64),
      "credential_ref" => "tenant-read"
    }

    create = %{
      "name" => "owned",
      "owner_token" => String.duplicate("c", 64),
      "incarnation" => String.duplicate("d", 32),
      "source" => source,
      "resources" => %{"cpus" => 1, "memory_mib" => 512, "storage_gib" => 1, "overlay_gib" => 1},
      "labels" => %{}
    }

    request = %{
      "operation" => "create_registry_prepared",
      "create" => create,
      "size_bytes" => 123
    }

    assert Request.valid?(request, 1000, 2)
    refute Request.valid?(request, 1000, 1)
    refute Request.valid?(%{request | "size_bytes" => 0}, 1000, 2)

    refute Request.valid?(
             put_in(request, ["create", "source", "identity_token"], "private"),
             1000,
             2
           )

    refute Request.valid?(%{"operation" => "create_oci", "create" => create}, 1000, 2)

    assert Request.valid?(
             %{"operation" => "inspect_registry_creation", "create" => create},
             30_000,
             2
           )

    refute Request.valid?(
             %{"operation" => "inspect_registry_creation", "create" => create},
             30_001,
             2
           )

    assert Request.observation?(%{"operation" => "inspect_registry_creation"})

    qualification = %{
      "operation" => "qualify_registry_creation",
      "source" => source,
      "resources" => create["resources"],
      "user" => nil
    }

    assert Request.valid?(qualification, 30_000, 2)
    refute Request.valid?(qualification, 30_001, 2)
    refute Request.valid?(qualification, 1000, 1)
  end

  test "credential IPC requires an exact reference-token pair and strips token from channel state" do
    request = %{
      "operation" => "prepare_artifact",
      "source" => source(),
      "credential_ref" => "tenant",
      "identity_token" => "private-token"
    }

    assert Request.valid?(request, 1000, 2)

    for changed <- [
          Map.delete(request, "identity_token"),
          Map.delete(request, "credential_ref"),
          Map.put(request, "identity_token", "bad token")
        ] do
      refute Request.valid?(changed, 1000, 2)
    end

    channel =
      Channel.new(%{
        "major" => 2,
        "minor" => 0,
        "epoch" => String.duplicate("ab", 16),
        "domain" => %{"target_id" => "test", "generation" => String.duplicate("cd", 16)}
      })

    assert {:ok, 1, channel} = Channel.register(channel, request, 262_144, 64)
    refute :erlang.term_to_binary(channel) =~ "private-token"
    assert channel.pending[1].operation["credential_ref"] == "tenant"
  end
end
