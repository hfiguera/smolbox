# Run in the same Linux consumer after exporting both sets of reports.
[directory, destination] = System.argv()

defmodule BenchmarkSummary do
  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 0,
      do: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2,
      else: Enum.at(sorted, div(n, 2))
  end

  def stats(values), do: %{median: median(values), min: Enum.min(values), max: Enum.max(values)}

  def counter(text, key) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split/1)
    |> Map.new(fn [name, value] -> {name, String.to_integer(value)} end)
    |> Map.fetch!(key)
  end

  def delta(report, file, key) do
    counter(report["counters_after"][file], key) - counter(report["counters_before"][file], key)
  end

  def total_delta(rows, file, key) do
    Enum.reduce(rows, 0, fn row, total -> total + delta(row, file, key) end)
  end
end

reports =
  for label <- ["direct", "nested"], sample <- 1..6 do
    report = File.read!(Path.join(directory, "#{label}-#{sample}.json")) |> Jason.decode!()
    ^label = report["label"]
    true = report["sample"] == to_string(sample)
    "passed" = report["status"]
    "0.1.3" = report["library_version"]
    "1.16.0" = report["runtime_version"]
    "verified_absent" = report["managed"]["cleanup"]
    2_666_664_666_667_000_000 = report["low_level"]["cpu"]["value"]

    for result <- [report["low_level"]["file"], report["managed"]["result"]] do
      37_748_736 = result["bytes"]
      "71b95e386e2cd1528baa69f1a206e039a50eafde3d2a4e1638c27cd70ce1e0fe" = result["sha256"]
    end

    outer_before = File.read!(Path.join(directory, "#{label}-#{sample}-outer-before.txt"))
    outer_after = File.read!(Path.join(directory, "#{label}-#{sample}-outer-after.txt"))

    Map.put(
      report,
      "outer_cpu_delta",
      Map.new(["nr_throttled", "throttled_usec"], fn key ->
        {key,
         BenchmarkSummary.counter(outer_after, key) - BenchmarkSummary.counter(outer_before, key)}
      end)
    )
  end

for key <- ["artifact_sha256", "source_sha256", "elixir", "otp"] do
  1 = reports |> MapSet.new(&Map.fetch!(&1, key)) |> MapSet.size()
end

metrics = [
  {"create_ms", ["low_level", "create_ms"]},
  {"start_ms", ["low_level", "start_ms"]},
  {"ready_ms", ["low_level", "ready_ms"]},
  {"tiny_client_ms", ["low_level", "tiny_client_ms"]},
  {"cpu_guest_ms", ["low_level", "cpu", "guest_ms"]},
  {"cpu_client_ms", ["low_level", "cpu", "client_ms"]},
  {"file_guest_ms", ["low_level", "file", "guest_ms"]},
  {"file_client_ms", ["low_level", "file", "client_ms"]},
  {"managed_collected_ms", ["managed", "submit_to_collected_ms"]},
  {"managed_cleanup_ms", ["managed", "submit_to_cleanup_ms"]}
]

summary =
  Map.new(metrics, fn {name, path} ->
    direct = reports |> Enum.filter(&(&1["label"] == "direct")) |> Enum.map(&get_in(&1, path))
    nested = reports |> Enum.filter(&(&1["label"] == "nested")) |> Enum.map(&get_in(&1, path))
    ratios = Enum.zip_with(nested, direct, &(&1 / &2))

    {name,
     %{
       direct: BenchmarkSummary.stats(direct),
       nested: BenchmarkSummary.stats(nested),
       ratio_of_medians: BenchmarkSummary.median(nested) / BenchmarkSummary.median(direct),
       paired_ratios: BenchmarkSummary.stats(ratios)
     }}
  end)

controls =
  Map.new(["direct", "nested"], fn label ->
    rows = Enum.filter(reports, &(&1["label"] == label))

    {label,
     %{
       throttled_usec: BenchmarkSummary.total_delta(rows, "cpu.stat", "throttled_usec"),
       throttled_periods: BenchmarkSummary.total_delta(rows, "cpu.stat", "nr_throttled"),
       memory_limit_events: BenchmarkSummary.total_delta(rows, "memory.events", "max"),
       oom_kills: BenchmarkSummary.total_delta(rows, "memory.events", "oom_kill"),
       outer_throttled_usec:
         Enum.reduce(rows, 0, fn row, total ->
           total + row["outer_cpu_delta"]["throttled_usec"]
         end)
     }}
  end)

evidence = %{
  status: "passed",
  measured_pairs: 6,
  unit: "milliseconds",
  statistics: summary,
  controls: controls,
  provenance: Path.join(directory, "metadata.json") |> File.read!() |> Jason.decode!(),
  samples: reports,
  warmups:
    Enum.map(["direct", "nested"], fn label ->
      report = Path.join(directory, "#{label}-warmup.json") |> File.read!() |> Jason.decode!()
      "passed" = report["status"]
      report
    end)
}

File.write!(destination, Jason.encode!(evidence, pretty: true) <> "\n")
IO.puts(Jason.encode!(%{statistics: summary, controls: controls}, pretty: true))
