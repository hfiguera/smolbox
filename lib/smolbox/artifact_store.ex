defmodule SmolBox.ArtifactStore do
  @moduledoc """
  Host-owned bounded file storage, independent of VM image preparation.

  `read` resolves an approved opaque input reference within a trusted host scope.
  It must enforce `max_bytes` while reading, not after unbounded buffering.
  `put` stores one bounded output snapshot under `{scope, execution_id, destination}`.
  Repeating the same digest must succeed; a different digest must fail without
  replacing the original snapshot. This makes collection recovery conservative
  when a guest changes its output between reads. All callbacks have a finite host
  I/O deadline and must not log payloads or credentials. SmolBox also bounds its
  observation of callbacks, but cannot roll back an already accepted storage write.

  Returned bytes and acknowledgments are revalidated by the runtime. References
  are host identifiers, never guest-selected URLs. Implementations own authorization,
  retention, at-rest protection, and crash-safe publication of file bytes.
  """

  alias SmolBox.Error

  @callback read(term(), String.t(), String.t(), pos_integer()) ::
              {:ok, binary()} | {:error, Error.t()}
  @callback put(term(), {String.t(), String.t()}, String.t(), binary(), String.t()) ::
              :ok | {:error, Error.t()}
end
