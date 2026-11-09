Code.require_file("embedded-runtime-proof-support.exs", __DIR__)

defmodule SmolBox.EmbeddedRuntimeProof do
  @moduledoc false
  alias SmolBox.EmbeddedRuntimeProofSupport, as: ProofSupport
  alias SmolBox.Example.EmbeddedPort

  def run(arguments) do
    options = ProofSupport.parse(arguments, terminal: :boolean)

    true = options[:without_rust]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    ProofSupport.configure_environment(options)

    tooling = Keyword.fetch!(options, :inventory_helper)
    Code.require_file(Path.join(tooling, "demo.ex"))
    {target, _binding} = Code.eval_file(Path.join(tooling, "config.example.exs"))
    before = ProofSupport.inventory(tooling)
    output = Path.expand(Keyword.fetch!(options, :output))
    evidence = EmbeddedPort.run(target, output, terminal: options[:terminal] || false)
    after_run = ProofSupport.inventory(tooling)
    true = before == after_run

    evidence =
      Map.merge(evidence, %{
        "scope" => "public-port-package-consumer",
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

SmolBox.EmbeddedRuntimeProof.run(System.argv())
