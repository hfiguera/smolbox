defmodule SmolBox.Embedded.CaptureStream do
  @moduledoc false
  alias SmolBox.Embedded.CaptureTransition
  @derive {Inspect, only: [:bytes]}
  defstruct [:max_bytes, :hash, bytes: 0]
  @max_events 68_719_476_737
  def max_events, do: @max_events

  def new(max_bytes),
    do: %__MODULE__{max_bytes: max_bytes, hash: :crypto.hash_init(:sha256)}

  # The consumer must acknowledge durable/local acceptance explicitly. No byte
  # credit is returned by Call until this completes; failed consumers are retired.
  def feed(stream, bytes, consumer) do
    if is_integer(stream.max_bytes) and stream.max_bytes in 1..68_719_476_736 and
         is_binary(bytes) and byte_size(bytes) in 1..65_536 and
         stream.bytes + byte_size(bytes) <= stream.max_bytes and is_function(consumer, 1) and
         consumer.({:checkpoint, bytes}) == :ok,
       do:
         {:ok,
          %{
            stream
            | bytes: stream.bytes + byte_size(bytes),
              hash: :crypto.hash_update(stream.hash, bytes)
          }},
       else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def complete?(stream, %{"result" => "captured", "transition" => wire}, request) do
    with {:ok, transition} <- CaptureTransition.from_wire(wire),
         true <-
           CaptureTransition.bound?(
             transition,
             request["receipt"],
             request["operation_id"],
             request["request"]
           ) do
      artifact = transition.change["artifact"]

      artifact["size_bytes"] == stream.bytes and
        artifact["sha256"] == Base.encode16(:crypto.hash_final(stream.hash), case: :lower)
    else
      _ -> false
    end
  end

  def complete?(_stream, %{"result" => "error"}, _request), do: true
  def complete?(_stream, _outcome, _request), do: false
end
