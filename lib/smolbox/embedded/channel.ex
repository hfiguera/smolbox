defmodule SmolBox.Embedded.Channel do
  @moduledoc false
  alias SmolBox.Embedded.{Request, Shape}
  alias SmolBox.Validation

  @derive {Inspect, only: [:last_id, :queued_bytes, :queued_events]}
  defstruct [
    :epoch,
    :domain,
    :minor,
    unavailable: false,
    last_id: 0,
    pending: %{},
    queued_bytes: 0,
    queued_events: 0
  ]

  def new(hello),
    do: %__MODULE__{epoch: hello["epoch"], domain: hello["domain"], minor: hello["minor"]}

  def register(channel, operation, bytes, events) do
    with false <- channel.unavailable,
         true <- map_size(channel.pending) < 32,
         true <- channel.last_id < 9_007_199_254_740_991,
         true <- Request.valid?(operation, 1),
         true <- Validation.integer?(bytes, 0, 262_144),
         true <- Validation.integer?(events, 0, 64),
         true <- domain_matches?(channel.domain, operation["receipt"]) do
      id = channel.last_id + 1

      pending = %{
        operation: operation,
        sequence: nil,
        done: false,
        credit: bytes,
        event_credit: events,
        output_bytes: 0,
        upload_bytes: 0,
        outstanding: :queue.new(),
        unacknowledged: 0
      }

      {:ok, id, %{channel | last_id: id, pending: Map.put(channel.pending, id, pending)}}
    else
      _invalid -> :error
    end
  end

  # Only structurally validated Protocol messages reach this correlation layer.
  # IDs remain recorded until a terminal AND consumption retire the subscription.
  def receive_message(
        %{minor: 4, unavailable: false} = channel,
        %{"type" => "unavailable", "epoch" => epoch}
      )
      when epoch == channel.epoch,
      do: {:ok, %{channel | unavailable: true}, :unavailable}

  def receive_message(channel, %{"epoch" => epoch, "id" => id} = message)
      when epoch == channel.epoch do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         false <- pending.done,
         {:ok, updated, event} <- advance(channel, pending, message) do
      delta_bytes = updated.unacknowledged - pending.unacknowledged
      delta_events = :queue.len(updated.outstanding) - :queue.len(pending.outstanding)

      {:ok,
       %{
         channel
         | pending: Map.put(channel.pending, id, updated),
           queued_bytes: channel.queued_bytes + delta_bytes,
           queued_events: channel.queued_events + delta_events
       }, {id, event}}
    else
      _invalid -> :error
    end
  end

  def receive_message(_channel, _message), do: :error

  def acknowledge(channel, id, bytes) do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         true <- Validation.integer?(bytes, 1, pending.unacknowledged),
         {:ok, outstanding, events} <- consume(pending.outstanding, bytes, 0) do
      updated = %{
        pending
        | outstanding: outstanding,
          unacknowledged: pending.unacknowledged - bytes,
          credit: pending.credit + bytes,
          event_credit: pending.event_credit + events
      }

      {:ok,
       %{
         channel
         | pending: Map.put(channel.pending, id, updated),
           queued_bytes: channel.queued_bytes - bytes,
           queued_events: channel.queued_events - events
       }, %{events: events, native_credit: not pending.done}}
    else
      _invalid -> :error
    end
  end

  def uploaded(channel, id, bytes) do
    with {:ok, pending} <- Map.fetch(channel.pending, id),
         false <- pending.done,
         %{"operation" => "write_file", "total_bytes" => total} <- pending.operation,
         true <- Validation.integer?(bytes, 1, min(65_536, total - pending.upload_bytes)) do
      updated = %{pending | upload_bytes: pending.upload_bytes + bytes}
      {:ok, %{channel | pending: Map.put(channel.pending, id, updated)}}
    else
      _invalid -> :error
    end
  end

  def retire(channel, id) do
    case Map.fetch(channel.pending, id) do
      {:ok, %{done: true, unacknowledged: 0}} ->
        {:ok, %{channel | pending: Map.delete(channel.pending, id)}}

      _invalid ->
        :error
    end
  end

  def close(channel),
    do: %{
      channel
      | pending: Map.new(channel.pending, fn {id, pending} -> {id, %{pending | done: true}} end)
    }

  def reject_unsent(channel, id) do
    case Map.fetch(channel.pending, id) do
      {:ok, %{sequence: nil, output_bytes: 0, upload_bytes: 0} = pending} ->
        {:ok, %{channel | pending: Map.put(channel.pending, id, %{pending | done: true})}}

      _invalid ->
        :error
    end
  end

  defp domain_matches?(_domain, nil), do: true

  defp domain_matches?(domain, receipt),
    do:
      receipt["target_id"] == domain["target_id"] and
        receipt["domain_generation"] == domain["generation"]

  defp advance(_channel, %{sequence: nil} = pending, %{"type" => "accepted", "sequence" => 0}),
    do: {:ok, %{pending | sequence: 0}, :accepted}

  defp advance(_channel, %{sequence: sequence} = pending, %{
         "type" => "event",
         "sequence" => next,
         "event" => event
       })
       when is_integer(sequence) and next == sequence + 1 do
    with {:ok, bytes} <- Shape.chunk(event["data_base64"]),
         {:ok, stream, limit} <- stream(pending.operation, event["stream"]),
         true <- byte_size(bytes) <= pending.credit and pending.event_credit > 0,
         true <- pending.output_bytes + byte_size(bytes) <= limit do
      updated = %{
        pending
        | sequence: next,
          credit: pending.credit - byte_size(bytes),
          event_credit: pending.event_credit - 1,
          output_bytes: pending.output_bytes + byte_size(bytes),
          unacknowledged: pending.unacknowledged + byte_size(bytes),
          outstanding: :queue.in(byte_size(bytes), pending.outstanding)
      }

      {:ok, updated, {:output, stream, bytes}}
    else
      _invalid -> :error
    end
  end

  defp advance(channel, pending, %{"type" => "terminal", "sequence" => next, "outcome" => outcome}) do
    if terminal_sequence?(pending.sequence, next) and
         terminal_matches?(channel.domain, pending, outcome),
       do: {:ok, %{pending | sequence: next, done: true}, {:terminal, outcome}},
       else: :error
  end

  defp advance(_channel, _pending, _message), do: :error

  defp terminal_sequence?(nil, 0), do: true
  defp terminal_sequence?(previous, next) when is_integer(previous), do: next == previous + 1
  defp terminal_sequence?(_previous, _next), do: false

  defp stream(%{"operation" => "exec", "command" => command}, "stdout"),
    do: {:ok, :stdout, command["max_output_bytes"]}

  defp stream(%{"operation" => "exec", "command" => command}, "stderr"),
    do: {:ok, :stderr, command["max_output_bytes"]}

  defp stream(%{"operation" => "read_file", "options" => options}, "file"),
    do: {:ok, :file, options["max_bytes"]}

  defp stream(_operation, _stream), do: :error

  defp terminal_matches?(_domain, pending, %{"result" => "error", "dispatch" => dispatch}),
    do: dispatch != "not_dispatched" or pending.output_bytes == 0

  defp terminal_matches?(_domain, %{operation: %{"operation" => "qualify_creation"}}, %{
         "result" => "qualified"
       }),
       do: true

  defp terminal_matches?(domain, %{operation: %{"operation" => "create", "create" => create}}, %{
         "result" => "created",
         "receipt" => receipt
       }),
       do:
         domain_matches?(domain, receipt) and
           Enum.all?(~w(name owner_token incarnation), &(receipt[&1] == create[&1]))

  defp terminal_matches?(_domain, %{operation: %{"operation" => "inspect_creation"}}, %{
         "result" => "creation_presence"
       }),
       do: true

  defp terminal_matches?(_domain, %{operation: %{"operation" => name}}, %{"result" => "observed"})
       when name in ~w(inspect start stop delete), do: true

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "exec", "command" => command}} = pending,
         %{"result" => "command"} = outcome
       ),
       do:
         outcome["output_bytes"] >= pending.output_bytes and
           outcome["output_bytes"] <= command["max_output_bytes"] and
           (outcome["completion"] != "exited" or outcome["output_bytes"] == pending.output_bytes) and
           (outcome["dispatch"] != "not_dispatched" or pending.output_bytes == 0)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "read_file", "options" => options}} = pending,
         %{"result" => "file"} = outcome
       ),
       do:
         outcome["observed_bytes"] >= pending.output_bytes and
           outcome["observed_bytes"] <= options["max_bytes"] and
           (outcome["completion"] != "completed" or
              outcome["observed_bytes"] == pending.output_bytes)

  defp terminal_matches?(
         _domain,
         %{operation: %{"operation" => "write_file", "total_bytes" => total}} = pending,
         %{"result" => "file"} = outcome
       ),
       do:
         outcome["observed_bytes"] <= total and
           (outcome["completion"] != "completed" or
              (outcome["observed_bytes"] == total and pending.upload_bytes == total))

  defp terminal_matches?(_domain, _pending, _outcome), do: false

  defp consume(queue, 0, events), do: {:ok, queue, events}

  defp consume(queue, bytes, events) do
    case :queue.out(queue) do
      {{:value, size}, rest} when bytes >= size -> consume(rest, bytes - size, events + 1)
      {{:value, size}, rest} -> {:ok, :queue.in_r(size - bytes, rest), events}
      {:empty, _queue} -> :error
    end
  end
end
