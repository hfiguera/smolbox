defmodule SmolBox.AdmissionReport do
  @moduledoc """
  Advisory admission explanation for a new disposable execution or retained machine.

  `required` includes guest memory plus profile overhead and both disk allocations.
  `blockers` can contain a worker health/drain status, `:unsupported_spec`,
  `:store_unavailable`, or `{:capacity, resource}` for each shortage. An empty list
  means only that these checks found no blocker at observation time.

  This neither accepts nor reserves work. Queue limits, deduplication, port claims,
  volume readiness/attachment claims, artifact preparation and concurrent changes
  can still prevent admission. Existing
  managed commands, branches, captures and exports have different accounting and
  are not assessed here. Measured CPU/memory utilization is never substituted for
  durable reservations. Poll explicitly to refresh; snapshots have no validity lease.
  """
  @enforce_keys [:worker, :required, :blockers, :checked_at_ms]
  defstruct @enforce_keys ++ [:reserved, :remaining, :usage_error]

  @type blocker ::
          :draining
          | :unavailable
          | :degraded
          | :incompatible
          | :unsupported_spec
          | :store_unavailable
          | {:capacity, :slots | :cpus | :memory_mb | :disk_gb}
  @type t :: %__MODULE__{
          worker: map(),
          required: SmolBox.Store.resources(),
          blockers: [blocker()],
          reserved: SmolBox.Store.resources() | nil,
          remaining: SmolBox.Store.resources() | nil,
          usage_error: SmolBox.Error.t() | nil,
          checked_at_ms: integer()
        }
end
