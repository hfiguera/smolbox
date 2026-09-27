defmodule SmolBox.ProvisioningMetrics do
  @moduledoc false

  def measure(config, function) do
    group = config["cgroup"]
    before = counters(group)
    {disk_before, races_before} = disk(config["worker_data"])
    memory_before = integer(group <> "/memory.current")

    {:ok, peak} =
      :file.open(String.to_charlist(group <> "/memory.peak"), [:read, :write, :raw, :binary])

    :ok = :file.write(peak, "0")
    sampler = Task.async(fn -> sample_disk(config["worker_data"], disk_before, 0) end)
    started = System.monotonic_time(:microsecond)

    try do
      result = function.()
      finished = System.monotonic_time(:microsecond)
      elapsed = (finished - started) / 1000
      after_counters = counters(group)
      {:ok, 0} = :file.position(peak, :bof)
      {:ok, bytes} = :file.read(peak, 128)
      memory_peak = bytes |> String.trim() |> String.to_integer()
      send(sampler.pid, :stop)
      {disk_peak, sampled_races} = Task.await(sampler, 30_000)
      {disk_after, races_after} = disk(config["worker_data"])

      {%{
         elapsed_ms: elapsed,
         started_us: started,
         finished_us: finished,
         worker_memory_before_bytes: memory_before,
         worker_memory_peak_bytes: memory_peak,
         worker_cpu_us: after_counters["usage_usec"] - before["usage_usec"],
         worker_throttled_us: after_counters["throttled_usec"] - before["throttled_usec"],
         worker_oom_kills: after_counters["oom_kill"] - before["oom_kill"],
         worker_disk_scan_races: races_before + sampled_races + races_after,
         worker_disk_before_bytes: disk_before,
         worker_disk_after_bytes: disk_after,
         worker_disk_sampled_peak_bytes: max(disk_peak, disk_after)
       }, result}
    after
      :file.close(peak)
      Task.shutdown(sampler, :brutal_kill)
    end
  end

  def disk(path) do
    {output, status} =
      System.cmd("du", ["-s", "-B1", "--", path], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    parse_disk(output, status, path)
  end

  def parse_disk(output, status, path) do
    lines = String.split(output, "\n", trim: true)
    {errors, [total]} = Enum.split(lines, -1)

    true =
      status == 0 or
        (status == 1 and errors != [] and
           Enum.all?(errors, &String.ends_with?(&1, "No such file or directory")))

    [bytes, ^path] = String.split(total, "\t", parts: 2)
    {String.to_integer(bytes), length(errors)}
  end

  defp sample_disk(path, peak, races) do
    receive do
      :stop -> {peak, races}
    after
      250 ->
        {bytes, vanished} = disk(path)
        sample_disk(path, max(peak, bytes), races + vanished)
    end
  end

  defp counters(group) do
    ["cpu.stat", "memory.events"]
    |> Enum.flat_map(fn file ->
      group |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)
    end)
    |> Map.new(fn line ->
      [key, value] = String.split(line)
      {key, String.to_integer(value)}
    end)
  end

  defp integer(path), do: path |> File.read!() |> String.trim() |> String.to_integer()
end
