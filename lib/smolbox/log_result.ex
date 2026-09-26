defmodule SmolBox.LogResult do
  @moduledoc """
  Bounded snapshot of machine console diagnostics, including boot/agent messages.

  Lines are lossy UTF-8 from upstream. These are not application stdout/stderr:
  smolvm 1.17.0 or 1.19.0 discards the startup workload's standard streams. There is no
  durable cursor, replay guarantee, or application-readiness/exit evidence.
  EOF only ends this observation. Treat log contents as potentially sensitive.
  """
  @derive {Inspect, only: [:source, :encoding]}
  defstruct lines: [], source: :console, encoding: :lossy_utf8
  @type t :: %__MODULE__{lines: [String.t()], source: :console, encoding: :lossy_utf8}
end
