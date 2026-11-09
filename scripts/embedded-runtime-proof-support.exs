defmodule SmolBox.EmbeddedRuntimeProofSupport do
  @moduledoc false

  @common_options [
    package: :string,
    fixture: :string,
    sha256: :string,
    domain_json: :string,
    inventory_helper: :string,
    output: :string,
    without_rust: :boolean
  ]

  def parse(arguments, extra_options) do
    {options, [], []} = OptionParser.parse(arguments, strict: @common_options ++ extra_options)
    options
  end

  def configure_environment(options) do
    package = Path.expand(Keyword.fetch!(options, :package))
    manifest = File.read!(Path.join(package, "package.json"))
    digest = Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)

    System.put_env([
      {"SMOLBOX_EMBEDDED_PACKAGE", package},
      {"SMOLBOX_EMBEDDED_MANIFEST_SHA256", digest},
      {"SMOLBOX_EMBEDDED_DOMAIN_JSON", Keyword.fetch!(options, :domain_json)},
      {"SMOLBOX_EMBEDDED_ARTIFACT", Keyword.fetch!(options, :fixture)},
      {"SMOLBOX_EMBEDDED_ARTIFACT_SHA256", Keyword.fetch!(options, :sha256)},
      {"SMOLBOX_EMBEDDED_INITIALIZE", "false"}
    ])
  end

  def inventory(tooling) do
    {body, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import sys,json; sys.path.insert(0,sys.argv[1]); from native_proof import snapshot; print(json.dumps(snapshot()))",
        tooling
      ])

    Jason.decode!(body)
  end
end
