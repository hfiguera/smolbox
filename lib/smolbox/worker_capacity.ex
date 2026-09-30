defmodule SmolBox.WorkerCapacity do
  @moduledoc """
  Read-only `/capacity` snapshot, qualified against smolvm 1.20.2.

  This is not configured admission capacity or the store's durable reservations.
  Allocations cover running machines; stopped machines and retained artifacts can
  still carry SmolBox reservations. CPU usage is fractional cores, not a percentage.
  Memory is reported in MiB; RSS can double count shared branch pages, while PSS
  accounts shared pages proportionally. Optional memory fields remain `nil` when
  unavailable. Host memory reflects the runtime's effective ceiling/availability
  where upstream supplies it; it does not certify isolation or quotas.

  `used_disk_gb` is upstream's integer disk-usage gauge, not free disk space or a
  complete inventory of checkpoint, export and backing files. `boot_id` identifies
  a serve process; a change does not prove a guest stopped or a reservation expired.
  `checked_at_ms` is the controller's receive time. No utilization estimate changes
  configured capacity, performs admission, or releases retained resources.
  """
  alias SmolBox.{Error, Observation, Validation}

  @fields [
    allocated_cpus: "allocated_cpus",
    allocated_memory_mb: "allocated_memory_mb",
    used_memory_mb: "used_memory_mb",
    used_memory_pss_mb: "used_memory_pss_mb",
    used_memory_private_mb: "used_memory_private_mb",
    used_memory_shared_mapped_mb: "used_memory_shared_mapped_mb",
    host_memory_total_mb: "host_memory_total_mb",
    host_memory_available_mb: "host_memory_available_mb",
    used_disk_gb: "used_disk_gb"
  ]
  @required [:allocated_cpus, :allocated_memory_mb, :used_memory_mb, :used_disk_gb]
  @enforce_keys [:used_cpus, :checked_at_ms] ++ @required
  defstruct [:boot_id, :used_cpus, :checked_at_ms] ++ Keyword.keys(@fields)

  @type t :: %__MODULE__{
          allocated_cpus: non_neg_integer(),
          allocated_memory_mb: non_neg_integer(),
          used_cpus: number(),
          used_memory_mb: non_neg_integer(),
          used_memory_pss_mb: non_neg_integer() | nil,
          used_memory_private_mb: non_neg_integer() | nil,
          used_memory_shared_mapped_mb: non_neg_integer() | nil,
          host_memory_total_mb: non_neg_integer() | nil,
          host_memory_available_mb: non_neg_integer() | nil,
          used_disk_gb: non_neg_integer(),
          boot_id: String.t() | nil,
          checked_at_ms: integer()
        }

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(body) do
    with {:ok, values} <- Observation.counters(body, @fields, @required, :capacity),
         cpu = body["used_cpus"],
         true <- is_number(cpu) and cpu >= 0 and cpu <= 1_048_576,
         boot = body["boot_id"],
         true <- is_nil(boot) or Validation.text?(boot, 256) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(values, %{
           used_cpus: cpu,
           boot_id: boot,
           checked_at_ms: System.system_time(:millisecond)
         })
       )}
    else
      _invalid -> Observation.invalid(:capacity)
    end
  end
end
