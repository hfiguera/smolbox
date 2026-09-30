defmodule SmolBox.WorkerReport do
  @moduledoc """
  On-demand worker diagnostics, with independent accounting and measurement results.

  `worker` is the existing `SmolBox.workers/1` health/configuration report; its
  status concerns new reservations, not ongoing commands or cleanup.
  `reserved` comes from the store's combined resource projection, including retained
  disks and helper resources. `remaining` is configured capacity minus reservations,
  clamped at zero, not free host resources. A store failure leaves both `nil`.

  `observed_capacity` is independent worker telemetry. Failure leaves it `nil` and
  sets `capacity_error`; it never supplies zero usage or changes admission. Reads
  are not atomic across the worker, coordinator and store. `checked_at_ms` is the
  completion time; retain neither this report nor its measurements as ownership
  evidence. Use `SmolBox.admission_report/2` for a particular new-machine request.
  """
  @enforce_keys [:worker, :checked_at_ms]
  defstruct @enforce_keys ++
              [:reserved, :remaining, :usage_error, :observed_capacity, :capacity_error]

  @type t :: %__MODULE__{
          worker: map(),
          checked_at_ms: integer(),
          reserved: SmolBox.Store.resources() | nil,
          remaining: SmolBox.Store.resources() | nil,
          usage_error: SmolBox.Error.t() | nil,
          observed_capacity: SmolBox.WorkerCapacity.t() | nil,
          capacity_error: SmolBox.Error.t() | nil
        }
end
