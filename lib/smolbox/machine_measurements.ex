defmodule SmolBox.MachineMeasurements do
  @moduledoc """
  Volatile measurements from a machine inspection, separate from ownership evidence.

  `machine` contains the validated identity and configured allocations. Measurements
  never participate in `SmolBox.Machine.same_incarnation?/2` or enter durable records.
  `checked_at_ms` is the controller's receive time, not an upstream sample timestamp.

  CPU counters describe the current VMM process and reset on restart; they are not
  CPU percentages or durable totals. Memory fields are host process measurements in
  MiB, not guest free memory. RSS summed across branches can count shared pages more
  than once; use PSS where available. Shared mapped memory is not a unique total.
  Disk is allocated host blocks in MiB, not provisioned disk capacity or guest free
  space. Egress is cumulative guest-outbound bytes, only available for supported
  virtio-net guests after reporting; it is not total network traffic or a rate.

  Missing/null measurements remain `nil`, including stopped-process CPU/memory.
  Zero is a real observation. Counters may reset and fields may be stale upstream;
  do not derive billing totals or release reservations from these snapshots.
  """
  alias SmolBox.{Error, Machine, Observation}

  @fields [
    cpu_seconds: "cpuSeconds",
    cpu_millis: "cpuMillis",
    rss_mb: "rssMb",
    pss_mb: "pssMb",
    private_memory_mb: "privateMemoryMb",
    shared_memory_mapped_mb: "sharedMemoryMappedMb",
    disk_used_mb: "diskUsedMb",
    egress_bytes: "egressBytes"
  ]
  @enforce_keys [:machine, :checked_at_ms]
  defstruct @enforce_keys ++ Keyword.keys(@fields)

  @type t :: %__MODULE__{
          machine: Machine.t(),
          checked_at_ms: integer(),
          cpu_seconds: non_neg_integer() | nil,
          cpu_millis: non_neg_integer() | nil,
          rss_mb: non_neg_integer() | nil,
          pss_mb: non_neg_integer() | nil,
          private_memory_mb: non_neg_integer() | nil,
          shared_memory_mapped_mb: non_neg_integer() | nil,
          disk_used_mb: non_neg_integer() | nil,
          egress_bytes: non_neg_integer() | nil
        }

  @doc false
  @spec from_wire(term()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(body) do
    with {:ok, machine} <- Machine.from_wire(body),
         {:ok, values} <- Observation.counters(body, @fields, [], :machine_measurements) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(values, %{machine: machine, checked_at_ms: System.system_time(:millisecond)})
       )}
    else
      {:error, error} -> {:error, %{error | operation: :machine_measurements}}
    end
  end
end
