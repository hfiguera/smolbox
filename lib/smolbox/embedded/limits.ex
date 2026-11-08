defmodule SmolBox.Embedded.Limits do
  @moduledoc """
  Finite controller-side budgets for an embedded bridge.

  These limits bound the broker independently of the native engine. They may
  tighten, never enlarge, the current Port protocol's bounds. Output credit is
  replenished only after consumption. The aggregate initial credit for all
  in-flight requests must fit both byte and event-count queue bounds. Capacity and guest allocations are separate
  operator declarations; these limits do not establish host resource quotas.
  """
  alias SmolBox.{Error, Validation}

  @bounds [
    in_flight: 32,
    send_queue_bytes: 4_194_304,
    event_queue_bytes: 8_388_608,
    event_queue_events: 2048,
    upload_bytes: 134_217_728,
    initial_credit_bytes: 262_144,
    initial_credit_events: 64,
    handshake_ms: 300_000,
    cancel_grace_ms: 5000,
    shutdown_ms: 15_000
  ]
  defstruct in_flight: 32,
            send_queue_bytes: 4_194_304,
            event_queue_bytes: 8_388_608,
            event_queue_events: 2048,
            upload_bytes: 134_217_728,
            initial_credit_bytes: 262_144,
            initial_credit_events: 64,
            handshake_ms: 120_000,
            cancel_grace_ms: 4000,
            shutdown_ms: 10_000

  @type t :: %__MODULE__{
          in_flight: pos_integer(),
          send_queue_bytes: pos_integer(),
          event_queue_bytes: pos_integer(),
          event_queue_events: pos_integer(),
          upload_bytes: pos_integer(),
          initial_credit_bytes: pos_integer(),
          initial_credit_events: pos_integer(),
          handshake_ms: pos_integer(),
          cancel_grace_ms: pos_integer(),
          shutdown_ms: pos_integer()
        }

  @doc "Construct bounded bridge limits without starting a process."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ []),
    do: Validation.construct(__MODULE__, options, [], Keyword.keys(@bounds))

  @doc false
  def validate(%__MODULE__{} = limits) do
    if Validation.struct_shape?(limits, __MODULE__) and
         Enum.all?(@bounds, fn {key, maximum} ->
           Validation.integer?(Map.fetch!(limits, key), 1, maximum)
         end) and
         limits.in_flight * limits.initial_credit_bytes <= limits.event_queue_bytes and
         limits.in_flight * limits.initial_credit_events <= limits.event_queue_events,
       do: :ok,
       else: invalid()
  end

  def validate(_limits), do: invalid()

  defp invalid, do: {:error, %Error{category: :validation, operation: :embedded}}
end
