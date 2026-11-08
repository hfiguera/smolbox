defmodule SmolBox.EmbeddedImagesRuntimeProof do
  @moduledoc false
  alias SmolBox.Example.EmbeddedImages

  def run(arguments) do
    {options, [], []} =
      OptionParser.parse(arguments,
        strict: [
          package: :string,
          fixture: :string,
          sha256: :string,
          domain_json: :string,
          inventory_helper: :string,
          output: :string,
          without_rust: :boolean,
          ordinary: :boolean,
          settings: :string
        ]
      )

    true = options[:without_rust] and options[:ordinary]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    package = Path.expand(Keyword.fetch!(options, :package))

    digest =
      package
      |> Path.join("package.json")
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    for {name, value} <- [
          {"SMOLBOX_EMBEDDED_PACKAGE", package},
          {"SMOLBOX_EMBEDDED_MANIFEST_SHA256", digest},
          {"SMOLBOX_EMBEDDED_DOMAIN_JSON", Keyword.fetch!(options, :domain_json)},
          {"SMOLBOX_EMBEDDED_ARTIFACT", Keyword.fetch!(options, :fixture)},
          {"SMOLBOX_EMBEDDED_ARTIFACT_SHA256", Keyword.fetch!(options, :sha256)},
          {"SMOLBOX_EMBEDDED_INITIALIZE", "false"}
        ],
        do: System.put_env(name, value)

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

    before = inventory(tooling)
    [] = before
    output = Path.expand(Keyword.fetch!(options, :output))
    {:ok, evidence} = EmbeddedImages.run(target, output, settings)
    after_run = inventory(tooling)
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

  defp inventory(tooling) do
    {body, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import sys,json; sys.path.insert(0,sys.argv[1]); from native_proof import snapshot; print(json.dumps(snapshot()))",
        tooling
      ])

    Jason.decode!(body)
  end
end

SmolBox.EmbeddedImagesRuntimeProof.run(System.argv())
