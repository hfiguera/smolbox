defmodule Mix.Tasks.Smolbox.Ci.VerifyChecks do
  @moduledoc "Verifies failing and passing canaries through real analyzer processes."
  @shortdoc "Prove the required quality checks detect defects"
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile", ["--warnings-as-errors"])
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(System.tmp_dir!(), "smolbox-canaries-#{suffix}")
    File.mkdir!(root)

    try do
      Enum.each(
        [:compiler, :credo, :ex_slop, :credence, :ex_dna, :dialyzer, :coverage],
        &verify(&1, root)
      )
    after
      File.rm_rf!(root)
    end
  end

  defp verify(tool, root) do
    Enum.each([:bad, :clean], fn variant ->
      directory = Path.join(root, "#{tool}/#{variant}")
      File.mkdir_p!(directory)
      fixture = "test/fixtures/quality/#{tool}_#{variant}.ex.fixture"
      source = File.read!(fixture)
      file = Path.join(directory, "canary.ex")
      File.write!(file, source)
      {output, status} = invoke(tool, directory, file)
      verify_result(tool, variant, status, output)
      if File.read!(file) != source, do: Mix.raise("#{tool} changed its input")
      Mix.shell().info("#{tool}: #{variant} canary verified (exit #{status})")
    end)
  end

  defp invoke(:compiler, directory, file), do: compile(directory, file)

  defp invoke(:coverage, directory, _file) do
    write_project(directory)
    File.mkdir!(Path.join(directory, "test"))
    File.write!(Path.join(directory, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(directory, "test/canary_test.exs"), """
    defmodule CanaryTest do
      use ExUnit.Case
      test "addition", do: assert(Canary.add(1, 2) == 3)
    end
    """)

    System.cmd("mix", ["test", "--cover", "--warnings-as-errors"],
      cd: directory,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp invoke(tool, directory, file) when tool in [:credo, :ex_slop] do
    {config, _binding} = Code.eval_file(".credo.exs")
    [default] = config.configs
    scoped = put_in(config.configs, [%{default | files: %{included: [file], excluded: []}}])
    config_file = Path.join(directory, ".credo.exs")
    File.write!(config_file, inspect(scoped, limit: :infinity))
    mix(["credo", "--strict", "--format", "json", "--config-file", config_file])
  end

  defp invoke(:credence, _directory, file), do: mix(["smolbox.ci.credence", file])

  defp invoke(:ex_dna, _directory, file) do
    mix(["ex_dna", file, "--max-clones", "0"])
  end

  defp invoke(:dialyzer, directory, file) do
    case compile(directory, file) do
      {_output, 0} -> :ok
      {output, status} -> Mix.raise("Dialyzer canary compilation failed (#{status}): #{output}")
    end

    plt = Dialyxir.Project.plt_file()
    unless File.regular?(plt), do: Mix.raise("Run mix dialyzer before canaries to build #{plt}")
    beams = Path.wildcard(Path.join(directory, "_build/test/lib/canary/ebin/*.beam"))
    elixir_ebin = :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("ebin")

    System.cmd("dialyzer", ["-pa", elixir_ebin, "--plt", plt, "--no_check_plt" | beams],
      stderr_to_stdout: true
    )
  end

  defp compile(directory, _file) do
    write_project(directory)

    System.cmd("mix", ["compile", "--warnings-as-errors"],
      cd: directory,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "test"}]
    )
  end

  defp write_project(directory) do
    File.write!(Path.join(directory, "mix.exs"), """
    defmodule Canary.MixProject do
      use Mix.Project
      def project do
        [app: :canary, version: "0.0.0", elixirc_paths: ["."],
         test_coverage: [summary: [threshold: 90]]]
      end
    end
    """)
  end

  defp mix(args), do: System.cmd("mix", args, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

  defp verify_result(_tool, :clean, 0, _output), do: :ok

  defp verify_result(tool, :bad, status, output) when status != 0 do
    unless String.contains?(output, expected(tool)) do
      Mix.raise("#{tool} failed for an unexpected reason (#{status}): #{output}")
    end
  end

  defp verify_result(tool, variant, status, output) do
    Mix.raise("#{tool} #{variant} canary returned unexpected exit #{status}: #{output}")
  end

  defp expected(:compiler), do: "unused"
  defp expected(:credo), do: "Credo.Check.Warning.IoInspect"
  defp expected(:ex_slop), do: "ExSlop.Check.Refactor.IdentityMap"
  defp expected(:credence), do: "no_identity_enum_map"
  defp expected(:ex_dna), do: "ExDNA found"
  defp expected(:dialyzer), do: "Invalid type specification"
  defp expected(:coverage), do: "Coverage test failed"
end
