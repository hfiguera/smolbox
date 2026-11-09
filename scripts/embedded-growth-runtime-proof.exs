Code.require_file("embedded-runtime-proof-support.exs", __DIR__)

defmodule SmolBox.EmbeddedGrowthRuntimeProof do
  @moduledoc false
  alias SmolBox.EmbeddedRuntimeProofSupport, as: ProofSupport
  alias SmolBox.Example.EmbeddedGrowth

  def run(arguments) do
    options = ProofSupport.parse(arguments, ordinary: :boolean, settings: :string)

    true = options[:without_rust] and options[:ordinary]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    ProofSupport.configure_environment(options)

    tooling = Keyword.fetch!(options, :inventory_helper)

    {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
      ~w(growth_control.ex growth_demo.ex)
      |> Enum.map(&Path.join(tooling, &1))
      |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

    {target, _binding} = Code.eval_file(Path.join(tooling, "config.example.exs"))

    settings =
      if path = options[:settings], do: EmbeddedGrowth.read_settings!(path), else: %{}

    {target, selection} = EmbeddedGrowth.configure_settings(target, settings)
    before = ProofSupport.inventory(tooling)
    output = Path.expand(Keyword.fetch!(options, :output))
    {:ok, evidence} = EmbeddedGrowth.run(target, output, selection)
    after_run = ProofSupport.inventory(tooling)
    true = before == after_run

    evidence =
      evidence
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "scope" => "public-port-package-consumer",
        "campaign" => "ordinary-public-native-growth",
        "public_native_admission_enabled" => true,
        "without_rust" => true,
        "inventory_before" => before,
        "inventory_after" => after_run
      })

    path = Path.join(output, "evidence.json")
    File.write!(path <> ".new", Jason.encode!(evidence), [:exclusive])
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
    IO.puts(Jason.encode!(evidence))
  end
end

SmolBox.EmbeddedGrowthRuntimeProof.run(System.argv())
