Code.require_file("embedded-runtime-proof-support.exs", __DIR__)

defmodule SmolBox.EmbeddedVolumeRuntimeProof do
  @moduledoc false
  alias SmolBox.EmbeddedRuntimeProofSupport, as: ProofSupport
  alias SmolBox.Example.EmbeddedVolumes

  def run(arguments) do
    options = ProofSupport.parse(arguments, volume_root: :string)

    true = options[:without_rust]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    ProofSupport.configure_environment(options)

    tooling = Keyword.fetch!(options, :inventory_helper)
    Code.require_file(Path.join(tooling, "volume_control.ex"))
    Code.require_file(Path.join(tooling, "volume_demo.ex"))
    {target, _binding} = Code.eval_file(Path.join(tooling, "config.example.exs"))
    before = ProofSupport.inventory(tooling)
    output = Path.expand(Keyword.fetch!(options, :output))
    target = EmbeddedVolumes.configure(target, Keyword.fetch!(options, :volume_root))
    {:ok, evidence} = EmbeddedVolumes.run(target, output)
    after_run = ProofSupport.inventory(tooling)
    true = before == after_run

    evidence =
      evidence
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{
        "scope" => "public-port-package-consumer",
        "campaign" => "ordinary-public-native-volumes",
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

SmolBox.EmbeddedVolumeRuntimeProof.run(System.argv())
