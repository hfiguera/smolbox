defmodule SmolBox.CI.Bounded do
  @moduledoc false
  alias SmolBox.CI.{Child, Util}

  def summary!(data, expected) do
    Util.ensure!(
      is_integer(expected) and expected > 0,
      "positive required suite size is necessary"
    )

    matches = Regex.scan(~r/^Result: (\d+) passed\s*$/m, data, capture: :all_but_first)
    seeds = Regex.scan(~r/^Running ExUnit with seed: (\d+),/m, data, capture: :all_but_first)

    Util.ensure!(
      matches == [[to_string(expected)]] and match?([_], seeds) and
        not Regex.match?(~r/\b(?:skipped|excluded)\b/, data),
      "required ExUnit cases did not all execute and pass"
    )

    [[seed]] = seeds
    %{passed: expected, seed: String.to_integer(seed)}
  end

  def run(arguments) do
    {options, command} =
      Util.options!(
        arguments,
        [report: :string, timeout: :integer, output_limit: :integer, expected_tests: :integer],
        [:report]
      )

    timeout = Keyword.get(options, :timeout, 1200)
    limit = Keyword.get(options, :output_limit, 4 * 1024 * 1024)
    Util.ensure!(timeout in 1..1800 and limit in 1024..8_388_608, "invalid runner bounds")

    Util.ensure!(
      !File.exists?(options[:report]) and command != [],
      "new report and command required"
    )

    # Reserve the report before launching anything, so concurrent invocations
    # using the same report cannot both execute the command.
    File.mkdir_p!(Path.dirname(options[:report]))

    report =
      File.open!(options[:report], [:write, :exclusive], fn file ->
        {data, report} = Child.execute(command, timeout: timeout * 1000, output_limit: limit)
        report = evidence(data, report, options[:expected_tests])
        IO.binwrite(file, [JSON.encode!(report), "\n"])
        report
      end)

    IO.puts(JSON.encode!(report))
    if report.status != "passed", do: System.halt(1)
  end

  defp evidence(_, report, nil), do: report

  defp evidence(data, %{status: "passed"} = report, expected) do
    Map.put(report, :tests, summary!(data, expected))
  rescue
    ArgumentError -> %{report | failure: "test_evidence", status: "failed"}
  end

  defp evidence(_, report, _), do: report
end
