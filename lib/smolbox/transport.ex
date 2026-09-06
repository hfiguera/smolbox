defmodule SmolBox.Transport do
  @moduledoc """
  Host-selected transport extension point. No callback may retry mutations.

  Implementations must validate HTTP status and media type, cap bodies before
  decoding, and redact failures. A returned error after possible dispatch cannot
  authorize replay. The default Req implementation is exercised against actual
  HTTP peers; replacing it transfers those obligations to the host adapter.
  """

  alias SmolBox.{Error, Result, Worker}

  @type request :: %{
          method: :get | :post | :put | :delete,
          path: String.t(),
          body: binary(),
          content_type: String.t(),
          accept: String.t(),
          max_bytes: pos_integer(),
          mode: :buffer | {:sse, pos_integer(), (SmolBox.Wire.SSE.event() -> any()) | nil}
        }

  @callback request(Worker.t(), request()) :: {:ok, binary() | Result.t()} | {:error, Error.t()}
end
