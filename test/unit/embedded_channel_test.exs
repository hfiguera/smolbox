defmodule SmolBox.Embedded.ChannelTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{Channel, Protocol}

  defp operation do
    Path.expand("../../native/smolbox-protocol/fixtures/exec-request.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("operation")
  end

  defp channel do
    receipt = operation()["receipt"]

    Channel.new(%{
      "minor" => 3,
      "epoch" => String.duplicate("ab", 16),
      "domain" => %{
        "target_id" => receipt["target_id"],
        "generation" => receipt["domain_generation"]
      }
    })
  end

  defp message(channel, id, sequence, type, fields \\ %{}),
    do:
      Map.merge(
        %{"type" => type, "epoch" => channel.epoch, "id" => id, "sequence" => sequence},
        fields
      )

  defp accepted(channel, id), do: message(channel, id, 0, "accepted")

  defp output(channel, id, sequence, bytes),
    do:
      message(channel, id, sequence, "event", %{
        "event" => %{"stream" => "stdout", "data_base64" => Base.encode64(bytes)}
      })

  defp terminal(channel, id, sequence, bytes, completion \\ "exited"),
    do:
      message(channel, id, sequence, "terminal", %{
        "outcome" => %{
          "result" => "command",
          "completion" => completion,
          "dispatch" => "may_have_dispatched",
          "observed_exit" => 0,
          "running_observed" => true,
          "output_bytes" => bytes
        }
      })

  defp receive!(channel, message) do
    assert {:ok, decoded} = Protocol.decode(Jason.encode!(message))
    assert {:ok, channel, event} = Channel.receive_message(channel, decoded)
    {channel, event}
  end

  test "versioned unavailability fences admission while results and credit remain consumable" do
    c = %{channel() | minor: 4}
    assert {:ok, 1, c} = Channel.register(c, operation(), 10, 2)
    {c, _accepted} = receive!(c, accepted(c, 1))
    notice = %{"type" => "unavailable", "epoch" => c.epoch}
    assert :error = Channel.receive_message(%{c | minor: 3}, notice)
    assert :error = Channel.receive_message(c, %{notice | "epoch" => String.duplicate("ef", 16)})
    {c, :unavailable} = receive!(c, notice)
    assert c.unavailable
    assert :error = Channel.register(c, operation(), 10, 2)
    assert :error = Channel.receive_message(c, notice)
    {c, {1, {:output, :stdout, "out"}}} = receive!(c, output(c, 1, 1, "out"))
    {c, {1, {:terminal, _outcome}}} = receive!(c, terminal(c, 1, 2, 3))
    assert :error = Channel.retire(c, 1)
    assert {:ok, c, %{native_credit: false}} = Channel.acknowledge(c, 1, 3)
    assert {:ok, c} = Channel.retire(c, 1)
    assert c.unavailable and c.pending == %{}
  end

  test "intent presence cannot stream, mint a receipt or satisfy a command" do
    receipt = operation()["receipt"]

    query = %{
      "operation" => "inspect_creation",
      "create" => %{
        "name" => receipt["name"],
        "owner_token" => receipt["owner_token"],
        "incarnation" => receipt["incarnation"],
        "labels" => %{},
        "artifact" => %{
          "path" => "/approved.smolmachine",
          "sha256" => String.duplicate("a", 64),
          "max_bytes" => 1024,
          "guest_platform" => "linux/arm64"
        },
        "resources" => %{"cpus" => 1, "memory_mib" => 512, "storage_gib" => 1, "overlay_gib" => 1}
      }
    }

    assert {:ok, 1, c} = Channel.register(channel(), query, 262_144, 64)
    {c, _} = receive!(c, accepted(c, 1))
    assert :error = Channel.receive_message(c, output(c, 1, 1, "bad"))

    minted =
      message(c, 1, 1, "terminal", %{"outcome" => %{"result" => "created", "receipt" => receipt}})

    assert :error = Channel.receive_message(c, minted)

    presence =
      message(c, 1, 1, "terminal", %{
        "outcome" => %{"result" => "creation_presence", "presence" => "absent"}
      })

    {_, {1, {:terminal, %{"presence" => "absent"}}}} = receive!(c, presence)
    assert {:ok, 1, command_channel} = Channel.register(channel(), operation(), 262_144, 64)
    {command_channel, _} = receive!(command_channel, accepted(command_channel, 1))
    assert :error = Channel.receive_message(command_channel, presence)
    invalid = put_in(presence, ["outcome", "presence"], "owned")
    assert :error = Protocol.decode(Jason.encode!(invalid))
  end

  test "acceptance remains scheduling evidence and stream routing rejects desynchronization" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 64)
    assert :error = Channel.receive_message(channel, output(channel, 1, 1, "early"))
    {channel, {1, :accepted}} = receive!(channel, accepted(channel, 1))
    assert :error = Channel.receive_message(channel, accepted(channel, 1))
    refute match?({:ok, _channel}, Channel.retire(channel, 1))

    for invalid <- [
          output(channel, 1, 2, "gap"),
          output(channel, 2, 1, "other-id"),
          output(channel, 1, 1, "stale") |> Map.put("epoch", String.duplicate("0", 32)),
          output(channel, 1, 1, "file") |> put_in(["event", "stream"], "file")
        ] do
      assert :error = Channel.receive_message(channel, invalid)
    end

    {channel, {1, {:output, :stdout, "out"}}} = receive!(channel, output(channel, 1, 1, "out"))

    {channel, {1, {:terminal, outcome}}} =
      receive!(channel, terminal(channel, 1, 2, 3, "native_error"))

    assert outcome["observed_exit"] == 0
    assert outcome["completion"] == "native_error"
    assert :error = Channel.receive_message(channel, terminal(channel, 1, 2, 3))
    assert :error = Channel.receive_message(channel, output(channel, 1, 3, "late"))
    refute inspect(channel) =~ "printf witness"
    refute inspect(channel) =~ operation()["receipt"]["owner_token"]
  end

  test "unread output remains charged after terminal and cannot accumulate across new calls" do
    channel =
      Enum.reduce(1..32, channel(), fn id, channel ->
        assert {:ok, ^id, channel} = Channel.register(channel, operation(), 262_144, 64)
        {channel, _event} = receive!(channel, accepted(channel, id))
        {channel, _event} = receive!(channel, output(channel, id, 1, "x"))
        {channel, _event} = receive!(channel, terminal(channel, id, 2, 1))
        channel
      end)

    assert channel.queued_bytes == 32
    assert channel.queued_events == 32
    assert :error = Channel.register(channel, operation(), 262_144, 64)
    refute match?({:ok, _channel}, Channel.retire(channel, 1))

    assert {:ok, channel, %{events: 1, native_credit: false}} = Channel.acknowledge(channel, 1, 1)
    assert {:ok, channel} = Channel.retire(channel, 1)
    assert channel.queued_bytes == 31
    assert channel.queued_events == 31
    assert {:ok, 33, _channel} = Channel.register(channel, operation(), 262_144, 64)
  end

  test "partial acknowledgments replenish bytes but preserve the outstanding message slot" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 1)
    {channel, _event} = receive!(channel, accepted(channel, 1))
    {channel, _event} = receive!(channel, output(channel, 1, 1, "ab"))
    assert :error = Channel.receive_message(channel, output(channel, 1, 2, "x"))
    assert {:ok, channel, %{events: 0, native_credit: true}} = Channel.acknowledge(channel, 1, 1)
    assert channel.queued_bytes == 1
    assert channel.queued_events == 1
    assert :error = Channel.receive_message(channel, output(channel, 1, 2, "x"))
    assert :error = Channel.acknowledge(channel, 1, 2)
    assert {:ok, channel, %{events: 1, native_credit: true}} = Channel.acknowledge(channel, 1, 1)
    assert channel.queued_events == 0
    {channel, _event} = receive!(channel, output(channel, 1, 2, "x"))
    assert channel.queued_events == 1
  end

  test "independent requests cannot satisfy each other's stream terminal or credits" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 64)
    assert {:ok, 2, channel} = Channel.register(channel, operation(), 262_144, 64)
    {channel, _event} = receive!(channel, accepted(channel, 1))
    {channel, _event} = receive!(channel, accepted(channel, 2))
    {channel, _event} = receive!(channel, output(channel, 1, 1, "first"))
    {channel, _event} = receive!(channel, output(channel, 2, 1, "other"))
    assert :error = Channel.receive_message(channel, terminal(channel, 1, 2, 4))
    assert {:ok, channel, _credit} = Channel.acknowledge(channel, 1, 5)
    assert channel.pending[2].unacknowledged == 5
    assert :error = Channel.acknowledge(channel, 1, 1)
    {channel, _event} = receive!(channel, terminal(channel, 1, 2, 5))
    assert {:ok, channel} = Channel.retire(channel, 1)
    assert Map.has_key?(channel.pending, 2)
  end

  test "pre-admission rejection retires without running evidence and IDs never repeat" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 64)

    rejection =
      message(channel, 1, 0, "terminal", %{
        "outcome" => %{
          "result" => "error",
          "code" => "overload",
          "dispatch" => "not_dispatched"
        }
      })

    {channel, {1, {:terminal, outcome}}} = receive!(channel, rejection)
    assert outcome["dispatch"] == "not_dispatched"
    assert {:ok, channel} = Channel.retire(channel, 1)
    assert {:ok, 2, channel} = Channel.register(channel, operation(), 262_144, 64)
    assert :error = Channel.receive_message(channel, accepted(channel, 1))

    stale = put_in(operation(), ["receipt", "domain_generation"], String.duplicate("0", 32))
    assert :error = Channel.register(channel, stale, 262_144, 64)
  end

  test "a completed file write requires every declared upload byte and a matching outcome" do
    write = %{
      "operation" => "write_file",
      "receipt" => operation()["receipt"],
      "total_bytes" => 3,
      "options" => %{"guest_path" => "/workspace/a", "max_bytes" => 3, "mode" => 384}
    }

    assert {:ok, 1, channel} = Channel.register(channel(), write, 0, 0)
    {channel, _event} = receive!(channel, accepted(channel, 1))

    completed =
      message(channel, 1, 1, "terminal", %{
        "outcome" => %{
          "result" => "file",
          "completion" => "completed",
          "dispatch" => "may_have_dispatched",
          "observed_bytes" => 3,
          "native_acknowledged" => true
        }
      })

    assert :error = Channel.receive_message(channel, completed)
    assert {:ok, channel} = Channel.uploaded(channel, 1, 2)
    assert :error = Channel.receive_message(channel, completed)
    assert :error = Channel.uploaded(channel, 1, 2)
    assert {:ok, channel} = Channel.uploaded(channel, 1, 1)
    {channel, {1, {:terminal, _outcome}}} = receive!(channel, completed)
    assert {:ok, _channel} = Channel.retire(channel, 1)
  end

  test "channel loss preserves unread charges without inventing a native terminal" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 64)
    {channel, _event} = receive!(channel, accepted(channel, 1))
    {channel, _event} = receive!(channel, output(channel, 1, 1, "unread"))
    assert :error = Channel.reject_unsent(channel, 1)
    closed = Channel.close(channel)
    assert closed.queued_bytes == 6
    assert closed.pending[1].sequence == 1
    assert :error = Channel.retire(closed, 1)
    assert {:ok, closed, %{native_credit: false}} = Channel.acknowledge(closed, 1, 6)
    assert {:ok, _closed} = Channel.retire(closed, 1)
  end

  test "known unsent retirement keeps monotonic IDs and cannot retire accepted work" do
    assert {:ok, 1, channel} = Channel.register(channel(), operation(), 262_144, 64)
    assert {:ok, channel} = Channel.reject_unsent(channel, 1)
    assert {:ok, channel} = Channel.retire(channel, 1)
    assert {:ok, 2, channel} = Channel.register(channel, operation(), 262_144, 64)
    {channel, _event} = receive!(channel, accepted(channel, 2))
    assert :error = Channel.reject_unsent(channel, 2)
  end
end
