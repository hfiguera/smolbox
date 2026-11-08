defmodule SmolBox.EmbeddedRuntimeProof do
  @moduledoc false
  alias SmolBox.Example.EmbeddedPort

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
          terminal: :boolean
        ]
      )

    true = options[:without_rust]
    nil = System.find_executable("rustc")
    nil = System.find_executable("cargo")
    package = Path.expand(Keyword.fetch!(options, :package))
    manifest = File.read!(Path.join(package, "package.json"))
    digest = Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)

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
    Code.require_file(Path.join(tooling, "demo.ex"))
    {target, _binding} = Code.eval_file(Path.join(tooling, "config.example.exs"))
    before = inventory(tooling)
    output = Path.expand(Keyword.fetch!(options, :output))
    evidence = EmbeddedPort.run(target, output, terminal: options[:terminal] || false)
    after_run = inventory(tooling)
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

SmolBox.EmbeddedRuntimeProof.run(System.argv())
