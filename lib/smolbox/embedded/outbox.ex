defmodule SmolBox.Embedded.Outbox do
  @moduledoc false
  alias SmolBox.Embedded.JSON
  @control_bytes 266_240
  @derive {Inspect, only: [:bytes, :control_bytes]}
  defstruct data: :queue.new(), controls: [], bytes: 0, control_bytes: 0

  def put(outbox, entry, limit) do
    case JSON.encode(entry.message) do
      {:ok, encoded} ->
        entry = Map.put(entry, :encoded, encoded)

        if entry.kind in [:credit, :cancel, :approve, :shutdown],
          do: control(outbox, entry),
          else: data(outbox, entry, limit)

      _invalid ->
        :error
    end
  end

  def next(%{controls: [entry | _rest]}), do: {:ok, entry}

  def next(outbox) do
    case :queue.peek(outbox.data) do
      {:value, entry} -> {:ok, entry}
      :empty -> :empty
    end
  end

  def pop(%{controls: [entry | rest]} = outbox),
    do: %{outbox | controls: rest, control_bytes: outbox.control_bytes - byte_size(entry.encoded)}

  def pop(outbox) do
    {{:value, entry}, rest} = :queue.out(outbox.data)
    %{outbox | data: rest, bytes: outbox.bytes - byte_size(entry.encoded)}
  end

  def drop_request(outbox, id) do
    data = :queue.to_list(outbox.data) |> Enum.reject(&(&1.id == id))
    controls = Enum.reject(outbox.controls, &(&1.id == id))

    %{
      outbox
      | data: :queue.from_list(data),
        controls: controls,
        bytes: size(data),
        control_bytes: size(controls)
    }
  end

  defp control(outbox, entry) do
    controls = merge_control(outbox.controls, entry)
    bytes = size(controls)

    if Enum.count_until(controls, 66) <= 65 and bytes <= @control_bytes and
         Enum.all?(controls, &bounded_control?/1),
       do: {:ok, %{outbox | controls: controls, control_bytes: bytes}},
       else: :error
  end

  defp bounded_control?(%{kind: :credit, message: message}),
    do: message["decoded_bytes"] <= 262_144 and message["events"] <= 64

  defp bounded_control?(_entry), do: true

  defp merge_control(controls, %{kind: :credit} = entry) do
    case Enum.find_index(controls, &(&1.kind == :credit and &1.id == entry.id)) do
      nil ->
        controls ++ [entry]

      index ->
        previous = Enum.at(controls, index)

        message =
          previous.message
          |> Map.update!("decoded_bytes", &(&1 + entry.message["decoded_bytes"]))
          |> Map.update!("events", &(&1 + entry.message["events"]))

        {:ok, encoded} = JSON.encode(message)
        List.replace_at(controls, index, %{entry | message: message, encoded: encoded})
    end
  end

  defp merge_control(controls, entry) do
    if Enum.any?(controls, &(&1.kind == entry.kind and &1.id == entry.id)),
      do: controls,
      else: controls ++ [entry]
  end

  defp data(outbox, entry, limit) do
    bytes = outbox.bytes + byte_size(entry.encoded)

    if bytes <= limit and terminal_slots?(outbox, entry),
      do: {:ok, %{outbox | data: :queue.in(entry, outbox.data), bytes: bytes}},
      else: :error
  end

  defp terminal_slots?(outbox, %{kind: :terminal_control, id: id}),
    do:
      Enum.count_until(
        :queue.to_list(outbox.data),
        &(&1.kind == :terminal_control and &1.id == id),
        2
      ) < 2

  defp terminal_slots?(_outbox, _entry), do: true

  defp size(entries),
    do: Enum.reduce(entries, 0, fn entry, size -> size + byte_size(entry.encoded) end)
end
