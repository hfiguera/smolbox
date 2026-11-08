defmodule SmolBox.Terminal.Connection.Transport do
  @moduledoc false
  alias SmolBox.Error
  alias SmolBox.Terminal.{Result, Spec}

  @type command ::
          {:input, binary()}
          | {:resize, pos_integer(), pos_integer()}
          | {:pong, binary()}
          | :attach
          | :close
  @type event ::
          {:output, binary()}
          | {:exit, Result.t()}
          | {:pong, binary()}
          | :ignore
          | :closed
          | {:error, atom()}
  @type failure :: {:error, Error.t()}

  # Each backend supplies an already approved source and a finite total input
  # budget. Open/send/poll/close must have finite I/O budgets and no retry/replay.
  @callback open(term(), String.t(), Spec.t()) :: {:ok, term(), non_neg_integer()} | failure()
  @callback input_cost(term(), command()) :: non_neg_integer()
  @callback send(term(), command()) :: {:ok, term()} | failure()
  # Events stay ordered and bounded, including malformed-event errors after a
  # valid prefix. A native Exit is publishable only after owned worker collection;
  # EOF or a close response alone is not Exit. No adapter persists a transcript.
  @callback poll(term()) :: {:ok, term(), [event()]} | failure()
  # Called once when a consumer removes an output event, never when it is queued.
  # Native adapters can return byte/event credit here; HTTP is a no-op.
  @callback acknowledge(term(), non_neg_integer()) :: {:ok, term()} | failure()
  @callback close(term()) :: term()
  # Asynchronous bridges deliver their bounded events to the controller's
  # mailbox. Passive HTTP transports continue to use poll/1.
  @callback handle_message(term(), term()) :: {:ok, term(), [event()]} | failure() | :ignore
  @optional_callbacks handle_message: 2
end
