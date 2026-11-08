defmodule SmolBox.EmbeddedCommandPayloadTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, CommandPayload, JSON, Protocol, Request, SDKIdentity}

  @fixture Path.expand(
             "../../native/smolbox-protocol/fixtures/buffered-command-request.json",
             __DIR__
           )
  test "shared compact fixture preserves NUL stdin and the original request identity" do
    fixture = Jason.decode!(File.read!(@fixture))

    command = %{
      "argv" => ["/bin/cat"],
      "env" => %{"PRIVATE" => "opaque"},
      "workdir" => "/workspace",
      "user" => nil,
      "stdin" => "hé\0stdin",
      "max_output_bytes" => 1024
    }

    operation = %{
      "operation" => "exec_buffered",
      "receipt" => fixture["operation"]["receipt"],
      "command" => command
    }

    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    assert {:ok, wire} = CommandPayload.pack(operation)
    assert wire == fixture["operation"]
    assert {:ok, _} = JSON.encode(fixture)
    assert operation["command"]["stdin"] == "hé\0stdin"
  end

  test "fully escaped valid argv env and stdin fit the unchanged frame cap" do
    command = %{
      "argv" => [
        String.duplicate("\x01", 16_384),
        String.duplicate("\x01", 16_384),
        String.duplicate("\x01", 16_384),
        String.duplicate("\x01", 16_384)
      ],
      "env" => Map.new(1..64, fn n -> {"K#{n}", String.duplicate("\x01", 8192)} end),
      "workdir" => "/workspace",
      "user" => nil,
      "stdin" => String.duplicate("\0", 65_536),
      "max_output_bytes" => 16_777_216
    }

    assert Request.buffered_command_valid?(command)
    assert :error = JSON.encode(command)

    assert {:ok, wire} =
             CommandPayload.pack(%{"operation" => "exec_buffered", "command" => command})

    assert {:ok, bytes} = JSON.encode(wire)
    assert byte_size(bytes) < 1_048_576

    raw =
      wire["command_payload"]["chunks"] |> Enum.map(&Base.decode64!/1) |> IO.iodata_to_binary()

    assert byte_size(raw) <= CommandPayload.limits()["payload_bytes"]
  end

  test "shared background codec and correlation keep PID acknowledgment separate from Exit" do
    fixture =
      @fixture
      |> Path.dirname()
      |> Path.join("background-command-request.json")
      |> File.read!()
      |> Jason.decode!()

    command = %{
      "argv" => ["/bin/sleep", "600"],
      "env" => %{"PRIVATE" => "opaque"},
      "workdir" => "/workspace",
      "user" => nil,
      "stdin" => nil,
      "max_output_bytes" => 128
    }

    operation = %{
      "operation" => "exec_background",
      "command" => command,
      "receipt" => fixture["operation"]["receipt"]
    }

    assert {:ok, encoded} = CommandPayload.pack(operation)
    assert encoded == fixture["operation"]
    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    invalid = put_in(operation, ["command", "stdin"], "forbidden")
    refute Request.valid?(invalid, 1000, 2)
    assert :error = CommandPayload.pack(invalid)
    assert Protocol.valid_outcome?(%{"result" => "launched", "pid" => 4242}, 2)
    refute Protocol.valid_outcome?(%{"result" => "launched", "pid" => 4242}, 1)
    refute Protocol.valid_outcome?(%{"result" => "launched", "pid" => 0}, 2)
    receipt = operation["receipt"]

    channel =
      Channel.new(%{
        "epoch" => fixture["epoch"],
        "major" => 2,
        "minor" => 0,
        "domain" => %{
          "target_id" => receipt["target_id"],
          "generation" => receipt["domain_generation"]
        }
      })

    assert {:ok, 1, channel} = Channel.register(channel, operation, 0, 0)
    accepted = %{"type" => "accepted", "epoch" => channel.epoch, "id" => 1, "sequence" => 0}
    assert {:ok, channel, _} = Channel.receive_message(channel, accepted)

    terminal = %{
      "type" => "terminal",
      "epoch" => channel.epoch,
      "id" => 1,
      "sequence" => 1,
      "outcome" => %{"result" => "launched", "pid" => 4242}
    }

    assert {:ok, channel, _} = Channel.receive_message(channel, terminal)
    assert {:ok, _} = Channel.retire(channel, 1)
    assert :error = Channel.receive_message(channel, terminal)
  end

  test "buffered support requires the job contract and invalid fields reject before packing" do
    sdk = SDKIdentity.implemented("1.22.0", String.duplicate("a", 40))

    refute SDKIdentity.valid?(
             update_in(sdk, ["feature_versions"], &Map.delete(&1, "job_resources"))
           )

    refute Request.buffered_command_valid?(%{})
    assert :error = CommandPayload.pack(%{"operation" => "exec_buffered", "command" => %{}})
  end

  test "shared streaming codec retains nil stdin and requires explicit buffered support" do
    fixture =
      @fixture
      |> Path.dirname()
      |> Path.join("streaming-command-request.json")
      |> File.read!()
      |> Jason.decode!()

    command = %{
      "argv" => ["/bin/sleep", "600"],
      "env" => %{"PRIVATE" => "opaque"},
      "workdir" => "/workspace",
      "user" => nil,
      "stdin" => nil,
      "max_output_bytes" => 128
    }

    operation = %{
      "operation" => "exec_stream",
      "receipt" => fixture["operation"]["receipt"],
      "command" => command
    }

    assert Request.valid?(operation, 1000, 2)
    refute Request.valid?(operation, 1000, 1)
    assert {:ok, packed} = CommandPayload.pack(operation)
    assert packed == fixture["operation"]
    invalid = put_in(operation, ["command", "stdin"], "forbidden")
    refute Request.valid?(invalid, 1000, 2)
    assert :error = CommandPayload.pack(invalid)
    sdk = SDKIdentity.implemented("1.22.0", String.duplicate("a", 40))

    refute SDKIdentity.valid?(
             update_in(sdk["feature_versions"], &Map.delete(&1, "buffered_exec"))
           )
  end
end
