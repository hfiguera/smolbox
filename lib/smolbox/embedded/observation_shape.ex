defmodule SmolBox.Embedded.ObservationShape do
  @moduledoc false
  alias SmolBox.Embedded.Shape
  alias SmolBox.Validation

  @capacity ~w(allocated_cpus allocated_memory_mb used_cpu_millis used_memory_mb
               used_memory_pss_mb used_memory_private_mb used_memory_shared_mapped_mb
               host_memory_total_mb host_memory_available_mb used_disk_gb boot_id)
  @required ~w(allocated_cpus allocated_memory_mb used_cpu_millis used_memory_mb used_disk_gb)
  @counters ~w(cpu_seconds cpu_millis rss_mb pss_mb private_memory_mb shared_memory_mapped_mb disk_used_mb egress_bytes)

  def health?(snapshot),
    do:
      Shape.keys?(snapshot, ~w(total running uptime_seconds)) and
        Validation.integer?(snapshot["total"], 0, 1_000_000) and
        Validation.integer?(snapshot["running"], 0, snapshot["total"]) and
        counter?(snapshot["uptime_seconds"])

  def capacity?(snapshot) do
    Shape.keys?(snapshot, @capacity) and
      Enum.all?(Map.drop(snapshot, ~w(boot_id)), fn {key, value} ->
        counter?(value) or (value == nil and key not in @required)
      end) and Validation.integer?(snapshot["used_cpu_millis"], 0, 1_048_576_000) and
      Shape.optional?(snapshot["boot_id"], &Shape.text?(&1, 256, false))
  end

  def counters?(counters),
    do:
      Shape.keys?(counters, @counters) and
        Enum.all?(counters, fn {_key, value} -> value == nil or counter?(value) end)

  defp counter?(value), do: Validation.integer?(value, 0, 18_446_744_073_709_551_615)
end
