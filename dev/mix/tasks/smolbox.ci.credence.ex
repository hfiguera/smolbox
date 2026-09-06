defmodule Mix.Tasks.Smolbox.Ci.Credence do
  @moduledoc "Runs read-only Credence pattern analysis with strict Unicode assumptions."
  @shortdoc "Check maintained Elixir sources with Credence"
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", ["--warnings-as-errors"])
    files = if args == [], do: maintained_files(), else: Enum.sort(args)

    if files == [] or (args == [] and Path.wildcard("lib/**/*.ex") == []) do
      Mix.raise("Credence scope must contain production source")
    end

    results =
      Task.async_stream(files, &analyze/1,
        max_concurrency: 4,
        timeout: 15_000,
        on_timeout: :kill_task,
        ordered: true
      )

    findings = Enum.flat_map(results, &unwrap/1)
    Enum.each(findings, fn finding -> Mix.shell().error(finding) end)
    Mix.shell().info("Credence checked #{length(files)} files with strict assumptions")
    if findings != [], do: Mix.raise("Credence found #{length(findings)} issue(s)")
  end

  defp maintained_files do
    ["lib/**/*.ex", "dev/**/*.ex", "test/**/*.{ex,exs}", "mix.exs", ".*.exs"]
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.reject(&String.starts_with?(&1, "test/fixtures/"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp analyze(file) do
    source = File.read!(file)
    Code.string_to_quoted!(source, file: file)

    source
    |> Credence.Pattern.analyze(assumptions: :strict)
    |> Enum.map(fn issue -> "#{file}: #{issue.rule}: #{issue.message}" end)
  end

  defp unwrap({:ok, issues}), do: issues
  defp unwrap({:exit, reason}), do: Mix.raise("Credence analysis failed: #{inspect(reason)}")
end
