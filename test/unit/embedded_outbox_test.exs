defmodule SmolBox.Embedded.OutboxTest do
  use ExUnit.Case, async: true
  alias SmolBox.Embedded.{JSON, Outbox}

  defp entry(kind, id, fields \\ %{}),
    do: %{
      kind: kind,
      id: id,
      message:
        Map.merge(
          %{"type" => Atom.to_string(kind), "epoch" => String.duplicate("a", 32), "id" => id},
          fields
        )
    }

  test "control reserve progresses when the encoded data queue is full" do
    data = entry(:request, 1)
    {:ok, encoded} = JSON.encode(data.message)
    limit = byte_size(encoded)
    assert {:ok, queue} = Outbox.put(%Outbox{}, data, limit)
    assert :error = Outbox.put(queue, entry(:request, 2), limit)
    assert {:ok, queue} = Outbox.put(queue, entry(:cancel, 1), limit)
    assert {:ok, %{kind: :cancel}} = Outbox.next(queue)
    assert {:ok, %{kind: :request}} = Outbox.next(Outbox.pop(queue))
    assert Outbox.drop_request(queue, 1) == %Outbox{}
  end

  test "pending credit coalesces a FIFO acknowledgment without exceeding native windows" do
    first = entry(:credit, 1, %{"decoded_bytes" => 1, "events" => 0})
    second = entry(:credit, 1, %{"decoded_bytes" => 2, "events" => 1})
    assert {:ok, queue} = Outbox.put(%Outbox{}, first, 1)
    assert {:ok, queue} = Outbox.put(queue, second, 1)
    assert {:ok, %{message: %{"decoded_bytes" => 3, "events" => 1}}} = Outbox.next(queue)
    assert [_entry] = queue.controls

    assert :error =
             Outbox.put(queue, entry(:credit, 1, %{"decoded_bytes" => 262_144, "events" => 1}), 1)

    assert :error =
             Outbox.put(queue, entry(:credit, 1, %{"decoded_bytes" => 1, "events" => 64}), 1)

    assert {:ok, queue} = Outbox.put(queue, entry(:cancel, 1), 1)
    assert {:ok, same} = Outbox.put(queue, entry(:cancel, 1), 1)
    assert same == queue
    assert Outbox.pop(Outbox.pop(queue)) == %Outbox{}
  end
end
