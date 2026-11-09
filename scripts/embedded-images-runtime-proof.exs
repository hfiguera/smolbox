Code.require_file("embedded-runtime-proof-support.exs", __DIR__)

defmodule SmolBox.EmbeddedImagesRuntimeProof do
  @moduledoc false
  alias SmolBox.EmbeddedRuntimeProofSupport, as: ProofSupport
  alias SmolBox.Example.EmbeddedImages

  def run(arguments) do
    options = ProofSupport.parse(arguments, ordinary: :boolean, settings: :string)

    true = options[:without_rust] and options[:ordinary]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    ProofSupport.configure_environment(options)

    tooling = Keyword.fetch!(options, :inventory_helper)

    {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
      ~w(images_control.ex images_demo.ex)
      |> Enum.map(&Path.join(tooling, &1))
      |> Kernel.ParallelCompiler.compile(return_diagnostics: true)

    {target, _} = Code.eval_file(Path.join(tooling, "config.example.exs"))
    settings_file = Keyword.fetch!(options, :settings)
    info = File.lstat!(settings_file)
    {uid, 0} = System.cmd(System.find_executable("id"), ["-u"])

    true =
      info.type == :regular and info.uid == String.to_integer(String.trim(uid)) and
        info.size <= 65_536 and Bitwise.band(info.mode, 0o077) == 0

    settings =
      File.open!(settings_file, [:read, :binary], fn stream ->
        bytes = IO.binread(stream, 65_537)
        true = is_binary(bytes) and byte_size(bytes) <= 65_536
        Jason.decode!(bytes)
      end)

    before = ProofSupport.inventory(tooling)
    [] = before
    output = Path.expand(Keyword.fetch!(options, :output))
    {:ok, evidence} = EmbeddedImages.run(target, output, settings)
    after_run = ProofSupport.inventory(tooling)
    true = before == after_run

    evidence =
      Map.merge(evidence, %{
        "scope" => "public-port-package-consumer",
        "without_rust" => true,
        "public_native_admission_enabled" => true,
        "inventory_before" => before,
        "inventory_after" => after_run
      })

    EmbeddedImages.save(output, "evidence", evidence)
    IO.puts(Jason.encode!(evidence))
  end
end

SmolBox.EmbeddedImagesRuntimeProof.run(System.argv())
