defmodule SmolBox.Terminal.Handle do
  @moduledoc """
  Ephemeral, single-consumer handle to a live controller-side terminal connection.
  Never persist this handle. It is not a durable session identity or host authorization.
  Only its bound consumer may read, write or resize. It cannot reattach a lost PTY.
  """
  @enforce_keys [:pid, :token]
  @derive {Inspect, only: []}
  defstruct [:pid, :token]
  @type t :: %__MODULE__{pid: pid(), token: reference()}
end
